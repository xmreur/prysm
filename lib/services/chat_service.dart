import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:prysm/constants/group_constants.dart';
import 'package:prysm/crypto/file_encrypt_worker.dart';
import 'package:prysm/crypto/crypto.dart';
import 'package:prysm/database/messages.dart';
import 'package:prysm/services/file_transfer_progress.dart';
import 'package:prysm/services/file_transfer_sender.dart';
import 'package:prysm/services/peer_identity_resolver.dart';
import 'package:prysm/services/pending_queue_reconciler.dart';
import 'package:prysm/services/side_channel_postman.dart';
import 'package:prysm/transport/transport_provider.dart';
import 'package:prysm/services/block_service.dart';
import 'package:prysm/services/disappearing_timer_service.dart';
import 'package:prysm/services/message_search_index_service.dart';
import 'package:prysm/util/battery_saver_policy.dart';
import 'package:prysm/util/disappearing_activity_notifier.dart';
import 'package:prysm/util/file_transfer_policy.dart';
import 'package:prysm/util/inbound_message_notifier.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/logging.dart';
import 'package:prysm/util/pending_message_db_helper.dart';
import 'package:prysm/util/tor_runtime_gate.dart';
import 'package:uuid/uuid.dart';

class ChatService {
  final String userId;
  final String peerId;
  final KeyManager keyManager;
  IdentityPublicKeys? peerIdentity;
  PrekeyBundle? peerPrekeyBundle;

  bool _isPolling = false;
  bool _isSending = false;
  bool _disposed = false;
  Future<void>? _outboundSendChain;
  int _pollIntervalSeconds = BatterySaverPolicy.chatPollActiveSeconds(false);
  int _consecutivePollErrors = 0;

  final _newMessagesController =
      StreamController<List<Map<String, dynamic>>>.broadcast();
  final _messageStatusController =
      StreamController<MessageStatusUpdate>.broadcast();
  final _peerReachableController = StreamController<bool>.broadcast();

  Stream<List<Map<String, dynamic>>> get onNewMessages =>
      _newMessagesController.stream;
  Stream<MessageStatusUpdate> get onMessageStatus =>
      _messageStatusController.stream;
  /// Emits true when a send/receive proves the peer is reachable.
  Stream<bool> get onPeerReachable => _peerReachableController.stream;

  /// Last time we successfully communicated with the peer.
  DateTime? lastSuccessfulActivity;

  int? _newestTimestamp;
  final Set<String> _seenMessageIds = {};
  final Set<String> _inFlightSends = {};
  final Set<String> _cancelledSends = {};
  StreamSubscription<InboundMessageEvent>? _inboundSub;
  StreamSubscription<Map<String, dynamic>>? _localInsertSub;

  late final PeerIdentityResolver _identityResolver;
  late final PendingQueueReconciler _reconciler;
  final SideChannelPostman _postman;

  ChatService({
    required this.userId,
    required this.peerId,
    required this.keyManager,
    PeerIdentityResolver? identityResolver,
    PendingQueueReconciler? pendingQueueReconciler,
    SideChannelPostman? postman,
  }) : _postman = postman ?? const _ChatTransportPostman() {
    _identityResolver =
        identityResolver ?? PeerIdentityResolver(peerId: peerId, keyManager: keyManager);
    _reconciler = pendingQueueReconciler ??
        PendingQueueReconciler(
          userId: userId,
          peerId: peerId,
          isDisposed: () => _disposed,
          hasPeerIdentity: () => peerIdentity != null,
          isInFlight: (wireId) => _inFlightSends.contains(wireId),
          requeue: (wireId) => resendMessage(wireId, processQueue: false),
          sendPending: (row) => _sendOverTor(
            row['id'] as String,
            row['message'] as String,
            row['type'] as String,
            replyToId: row['replyTo'] as String?,
            fileName: row['fileName'] as String?,
            fileSize: row['fileSize'] as int?,
            viewOnce: (row['viewOnce'] ?? 0) == 1,
            expiresAt: row['expiresAt'] as int?,
            timestamp: row['timestamp'] as int?,
          ),
          markAsSent: _markAsSent,
        );
  }

  void dispose() {
    _disposed = true;
    _isPolling = false;
    _isSending = false;
    _inboundSub?.cancel();
    _inboundSub = null;
    _localInsertSub?.cancel();
    _localInsertSub = null;
    _newMessagesController.close();
    _messageStatusController.close();
    _peerReachableController.close();
  }

  // PUBLIC API

  Future<bool> initialize(String? peerIdentityJson) async {
    if (peerIdentityJson != null &&
        peerIdentityJson.isNotEmpty &&
        peerIdentityJson != 'NONE') {
      try {
        peerIdentity = keyManager.importPeerIdentity(peerIdentityJson);
        return true;
      } catch (e) {
        Logging.error('Invalid cached peer identity: $e', 'ChatService');
      }
    }

    final cached = await _identityResolver.getCachedIdentityJson();
    if (cached != null) {
      try {
        peerIdentity = keyManager.importPeerIdentity(cached);
        return true;
      } catch (e) {
        Logging.error('Invalid peer identity in database: $e', 'ChatService');
      }
    }
    return await _fetchPeerIdentityOverTor();
  }

  void startPolling() {
    if (_isPolling) return;
    _isPolling = true;
    _subscribeInbound();
    _subscribeLocalInserts();
    _loopPoll();
  }

  @visibleForTesting
  void startInboundPushListener() {
    _subscribeInbound();
  }

  void _subscribeInbound() {
    _inboundSub ??= InboundMessageNotifier.instance.onInboundMessage.listen(
      _onInboundMessage,
    );
  }

  void _onInboundMessage(InboundMessageEvent event) {
    if (_disposed) return;
    if (event.groupId != null) return;
    if (event.senderId != peerId) return;
    _deliverNewRows([event.row]);
  }

  void _subscribeLocalInserts() {
    _localInsertSub ??= MessagesDb.onMessageInserted.listen(_onLocalInsert);
  }

  void _onLocalInsert(Map<String, dynamic> row) {
    if (_disposed) return;
    final groupId = row['groupId'] as String?;
    if (groupId != null) return;

    final senderId = row['senderId'] as String?;
    final receiverId = row['receiverId'] as String?;
    final isDirectForPeer =
        (senderId == userId && receiverId == peerId) ||
            (senderId == peerId && receiverId == userId);
    if (!isDirectForPeer) return;

    _deliverNewRows([row]);
  }

  void stopPolling() {
    _isPolling = false;
  }

  void startSendQueue() {
    unawaited(reconcilePendingQueue().whenComplete(_processSendQueue));
  }

  /// Re-queues outbound messages that show as pending in the UI but were
  /// dropped from the pending_messages retry table (e.g. after a failed send
  /// before the queue insert, or app restart during a long Tor timeout).
  Future<void> reconcilePendingQueue() => _reconciler.reconcile();

  /// Avoid re-processing historical messages on the first poll after chat open.
  void seedNewestTimestamp(int timestamp) {
    if (_newestTimestamp == null || timestamp > _newestTimestamp!) {
      _newestTimestamp = timestamp;
    }
  }

  Future<String?> sendTextMessage(
    String text, {
    String? replyToId,
    String? messageId,
  }) async {
    if (BlockService.instance.isBlocked(peerId)) return null;
    if (peerIdentity == null) return null;

    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final id =
        messageId ?? const Uuid().v4(); // ✅ Use provided ID or generate new
    final expiresAt = await DisappearingTimerService.expiresAtForSend(
      peerId,
      at: DateTime.fromMillisecondsSinceEpoch(timestamp),
    );

    final encryptedForPeer = await keyManager.encryptForPeer(
      text,
      peerIdentity!,
      peerId: peerId,
      peerPrekey: peerPrekeyBundle,
    );
    final encryptedForSelf = await keyManager.encryptForSelf(text);

    await MessagesDb.insertMessage({
      'id': id,
      'senderId': userId,
      'receiverId': peerId,
      'message': encryptedForSelf,
      'type': 'text',
      'status': 'pending',
      'timestamp': timestamp,
      'replyTo': replyToId,
      'expiresAt': ?expiresAt,
    }, notifyListeners: false);

    await MessageSearchIndexService.indexBestEffort(
      () => MessageSearchIndexService(
        keyManager: keyManager,
        userId: userId,
      ).indexOutboundDirectText(
        messageId: id,
        peerId: peerId,
        timestamp: timestamp,
        plaintext: text,
      ),
    );

    if (expiresAt != null) {
      DisappearingActivityNotifier.instance.notify();
    }

    final success = await _sendOverTor(
      id,
      encryptedForPeer,
      'text',
      replyToId: replyToId,
      expiresAt: expiresAt,
      timestamp: timestamp,
    );

    // If the user deleted the message while the send was in flight, do not
    // mark it as sent or re-queue it.
    final stored = await MessagesDb.getMessageById(id);
    if (stored.isEmpty || stored.first['deletedAt'] != null) {
      await PendingMessageDbHelper.removeOutboundPendingForWireId(id);
      return id;
    }

    if (success) {
      await _markAsSent(id);
      _notifyPeerReachable();
      // Peer is reachable — flush any pending messages
      _processSendQueue();
    } else {
      await _addToPendingQueue(
        id,
        encryptedForPeer,
        'text',
        replyToId: replyToId,
        expiresAt: expiresAt,
        timestamp: timestamp,
      );
      _processSendQueue();
    }

    return id;
  }

  Future<String?> sendFileMessage(
    Uint8List bytes,
    String fileName,
    String type, {
    String? replyToId,
    String? messageId,
    bool viewOnce = false,
  }) async {
    if (BlockService.instance.isBlocked(peerId)) return null;
    if (peerIdentity == null) return null;
    if (!FileTransferPolicy.isWithinMaxFileSize(bytes.length)) {
      Logging.error(FileTransferPolicy.maxFileSizeError, 'ChatService');
      return null;
    }

    // Let the optimistic bubble paint before heavy encryption.
    await SchedulerBinding.instance.endOfFrame;
    final payload = await _encryptFilePayload(bytes);

    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final id =
        messageId ?? const Uuid().v4(); // ✅ Use provided ID or generate new
    final expiresAt = await DisappearingTimerService.expiresAtForSend(
      peerId,
      at: DateTime.fromMillisecondsSinceEpoch(timestamp),
    );

    await MessagesDb.insertMessage({
      'id': id,
      'senderId': userId,
      'receiverId': peerId,
      'message': payload['selfPayload'],
      'type': type,
      'fileName': fileName,
      'fileSize': bytes.length,
      'timestamp': timestamp,
      'replyTo': replyToId,
      'status': 'pending',
      'viewOnce': viewOnce ? 1 : 0,
      'expiresAt': ?expiresAt,
    }, notifyListeners: false);

    // ponytail: guard instead of a viewOnce param on indexOutboundFile — the
    // sender of a view-once file can never open it, so its name stays indexed.
    if (!viewOnce) {
      await MessageSearchIndexService.indexBestEffort(
        () => MessageSearchIndexService(
          keyManager: keyManager,
          userId: userId,
        ).indexOutboundFile(
          messageId: id,
          conversationId: peerId,
          scope: 'direct',
          timestamp: timestamp,
          fileName: fileName,
        ),
      );
    }

    if (expiresAt != null) {
      DisappearingActivityNotifier.instance.notify();
    }

    final wsConnected = TransportProvider.isConfigured &&
        TransportProvider.instance.isRealtimeConnected(peerId);
    final peerSupports = TransportProvider.isConfigured &&
        TransportProvider.instance.wsManager
            .peerSupportsFileTransfer(peerId);
    if (FileTransferPolicy.shouldUseChunkedTransfer(
      fileSizeBytes: bytes.length,
      wsConnected: wsConnected,
      peerSupportsFileTransfer: peerSupports,
    )) {
      FileTransferProgress.uploadNotifier(id);
    }

    final success = await _sendOverTor(
      id,
      payload['peerPayload']!,
      type,
      fileName: fileName,
      fileSize: bytes.length,
      replyToId: replyToId,
      viewOnce: viewOnce,
      expiresAt: expiresAt,
      timestamp: timestamp,
    );

    if (!success) {
      FileTransferProgress.clearUpload(id);
    }

    // If the user deleted the message while the send was in flight, do not
    // mark it as sent or re-queue it.
    final stored = await MessagesDb.getMessageById(id);
    if (stored.isEmpty || stored.first['deletedAt'] != null) {
      await PendingMessageDbHelper.removeOutboundPendingForWireId(id);
      return id;
    }

    if (success) {
      await _markAsSent(id);
      _notifyPeerReachable();
      // Peer is reachable — flush any pending messages
      _processSendQueue();
    } else {
      await _addToPendingQueue(
        id,
        payload['peerPayload']!,
        type,
        fileName: fileName,
        fileSize: bytes.length,
        replyToId: replyToId,
        viewOnce: viewOnce,
        expiresAt: expiresAt,
        timestamp: timestamp,
      );
      _processSendQueue();
    }

    return id;
  }

  // Private methods

  Future<void> _loopPoll() async {
    while (_isPolling && !_disposed) {
      try {
        final hadNew = await _fetchNewMessages();
        _consecutivePollErrors = 0;
        _pollIntervalSeconds = _effectivePollIntervalSeconds(hadNew);
      } catch (e) {
        Logging.error('Polling error: $e', 'ChatService');
        _consecutivePollErrors++;
        final base = BatterySaverPolicy.chatPollActiveSeconds();
        _pollIntervalSeconds = min(30, base * (1 << _consecutivePollErrors));
      }

      if (_isPolling && !_disposed) {
        await Future.delayed(Duration(seconds: _pollIntervalSeconds));
      }
    }
  }

  int _effectivePollIntervalSeconds(bool hadNew) {
    if (TransportProvider.isConfigured &&
        TransportProvider.instance.isRealtimeConnected(peerId)) {
      return BatterySaverPolicy.wsSafetyPollSeconds;
    }
    return hadNew
        ? BatterySaverPolicy.chatPollActiveSeconds()
        : BatterySaverPolicy.chatPollIdleSeconds();
  }

  Future<bool> _fetchNewMessages() async {
    final batch = await MessagesDb.getMessagesBetweenBatch(
      userId,
      peerId,
      limit: 20,
      beforeTimestamp: null,
    );

    if (batch.isEmpty) return false;
    return _deliverNewRows(batch);
  }

  bool _deliverNewRows(List<Map<String, dynamic>> rows) {
    if (_disposed) return false;

    final newMessages = rows.where((msg) {
      final id = msg['id'] as String;
      if (_seenMessageIds.contains(id)) return false;
      if (_newestTimestamp != null &&
          (msg['timestamp'] as int) <= _newestTimestamp!) {
        return false;
      }
      return true;
    }).toList();

    if (newMessages.isEmpty) return false;

    for (final msg in newMessages) {
      _seenMessageIds.add(msg['id'] as String);
    }

    _newestTimestamp = newMessages
        .map((m) => m['timestamp'] as int)
        .reduce(max);

    final hasNewPeerMessage =
        newMessages.any((msg) => msg['senderId'] == peerId);
    if (hasNewPeerMessage) {
      _notifyPeerReachable();
    }

    if (!_disposed) {
      _newMessagesController.add(newMessages);
    }
    return true;
  }

  static const int _maxRetries = 50;
  final Map<String, int> _retryCounts = {};

  Future<void> _processSendQueue() async {
    if (_isSending || _disposed || TorRuntimeGate.blocked) return;
    if (BlockService.instance.isBlocked(peerId)) return;
    _isSending = true;

    int consecutiveFailures = 0;

    try {
      await reconcilePendingQueue();

      while (!_disposed) {
        final pending =
            await PendingMessageDbHelper.getPendingMessages(receiverId: peerId);
        if (pending.isEmpty) break;

        final List<String> removeIds = [];
        var sentAny = false;

        for (final msg in pending) {
          if (_disposed) break;

          final type = msg['type'] as String?;
          if (type != null && isSideChannelPendingType(type)) {
            continue;
          }

          final msgId = msg['id'] as String;

          // Skip messages that were deleted while queued. This prevents a
          // pending message from being delivered after the user deletes it.
          final stored = await MessagesDb.getMessageById(msgId);
          if (stored.isEmpty ||
              stored.first['deletedAt'] != null ||
              _cancelledSends.contains(msgId)) {
            removeIds.add(msgId);
            continue;
          }

          final retries = _retryCounts[msgId] ?? 0;

          if (retries >= _maxRetries) {
            removeIds.add(msgId);
            _retryCounts.remove(msgId);
            if (!_disposed) {
              _messageStatusController.add(MessageStatusUpdate(msgId, 'failed'));
            }
            continue;
          }

          final success = await _sendOverTor(
            msg['id'],
            msg['message'],
            msg['type'],
            replyToId: msg['replyTo'],
            fileName: msg['fileName'],
            fileSize: msg['fileSize'],
            viewOnce: (msg['viewOnce'] ?? 0) == 1,
            expiresAt: msg['expiresAt'] as int?,
            timestamp: msg['timestamp'] as int?,
          );

          if (success) {
            removeIds.add(msgId);
            _retryCounts.remove(msgId);
            await _markAsSent(msgId);
            if (!_disposed) {
              _messageStatusController.add(MessageStatusUpdate(msgId, 'sent'));
            }
            consecutiveFailures = 0;
            sentAny = true;
            _notifyPeerReachable();
          } else {
            _retryCounts[msgId] = retries + 1;
            consecutiveFailures++;
          }
        }

        if (removeIds.isNotEmpty) {
          await PendingMessageDbHelper.removeMessages(removeIds);
        }

        final remaining =
            await PendingMessageDbHelper.getPendingMessages(receiverId: peerId);
        if (remaining.isEmpty) break;

        if (sentAny) {
          continue;
        }

        // Backoff: 2s, 4s, 8s, 16s, max 30s
        final backoff = min(30, 2 * (1 << min(consecutiveFailures, 4)));
        final jitter = Random().nextInt(max(1, backoff ~/ 2));
        await Future.delayed(Duration(seconds: backoff + jitter));
      }
    } finally {
      _isSending = false;
    }
  }

  Future<T> _serializedOutbound<T>(Future<T> Function() action) {
    final previous = _outboundSendChain ?? Future<void>.value();
    final run = previous.then((_) => action());
    _outboundSendChain = run.then((_) {}, onError: (_) {});
    return run;
  }

  Future<bool> _sendOverTor(
    String id,
    String encrypted,
    String type, {
    String? replyToId,
    String? fileName,
    int? fileSize,
    bool viewOnce = false,
    int? expiresAt,
    int? timestamp,
  }) {
    return _serializedOutbound(() async {
    if (BlockService.instance.isBlocked(peerId)) return false;
    if (TorRuntimeGate.blocked) return false;

    final wireTimestamp = timestamp ?? DateTime.now().millisecondsSinceEpoch;
    final isLargeMedia = type == 'file' || type == 'image' || type == 'audio';
    final timeout = isLargeMedia
        ? const Duration(minutes: 5)
        : const Duration(seconds: 30);

    if (isLargeMedia && fileName != null && fileSize != null) {
      final chunked = await _trySendChunkedFile(
        id: id,
        encrypted: encrypted,
        type: type,
        fileName: fileName,
        fileSize: fileSize,
        replyToId: replyToId,
        viewOnce: viewOnce,
        timeout: timeout,
        expiresAt: expiresAt,
        timestamp: wireTimestamp,
      );
      if (chunked) return true;

      Logging.error(
        'Chunked file transfer failed for $id, falling back to HTTP send',
        'ChatService',
      );
    }

    try {
      _inFlightSends.add(id);
      await _postman.postDirect(
        peerId: peerId,
        payload: {
          'id': id,
          'senderId': userId,
          'receiverId': peerId,
          'message': encrypted,
          'type': type,
          'fileName': fileName,
          'fileSize': fileSize,
          'replyTo': replyToId,
          'viewOnce': viewOnce,
          'timestamp': wireTimestamp,
          'expiresAt': ?expiresAt,
        },
        timeout: timeout,
      );
      return true;
    } on TimeoutException {
      Logging.error('Send timeout for $type message', 'ChatService');
      return false;
    } catch (e) {
      Logging.error('Send deferred (queued for retry): $e', 'ChatService');
      return false;
    } finally {
      _inFlightSends.remove(id);
    }
    });
  }

  Future<bool> _trySendChunkedFile({
    required String id,
    required String encrypted,
    required String type,
    required String fileName,
    required int fileSize,
    String? replyToId,
    bool viewOnce = false,
    required Duration timeout,
    int? expiresAt,
    int? timestamp,
  }) async {
    if (!TransportProvider.isConfigured) return false;

    final wsConnected = TransportProvider.instance.isRealtimeConnected(peerId);
    final peerSupports =
        TransportProvider.instance.wsManager.peerSupportsFileTransfer(peerId);
    if (!FileTransferPolicy.shouldUseChunkedTransfer(
      fileSizeBytes: fileSize,
      wsConnected: wsConnected,
      peerSupportsFileTransfer: peerSupports,
    )) {
      return false;
    }

    try {
      _inFlightSends.add(id);
      final sender = FileTransferSender(TransportProvider.instance.wsManager);
      return await sender.send(
        peerOnion: peerId,
        messageId: id,
        senderId: userId,
        receiverId: peerId,
        type: type,
        fileName: fileName,
        fileSize: fileSize,
        peerPayload: encrypted,
        replyToId: replyToId,
        viewOnce: viewOnce,
        timeout: timeout,
        expiresAt: expiresAt,
        timestamp: timestamp,
      );
    } catch (e) {
      Logging.error('Chunked file send failed: $e', 'ChatService');
      return false;
    } finally {
      _inFlightSends.remove(id);
    }
  }

  Future<Map<String, String>> _encryptFilePayload(Uint8List bytes) async {
    final peer = peerIdentity!;
    final identityJson = await identityPrivateJsonForIsolate(keyManager.identity);
    final peerAgreeBytes = Uint8List.fromList(peer.agreePublic.bytes);
    return encryptFileInBackground(
      bytes: bytes,
      identityPrivateJson: identityJson,
      peerAgreePublicBytes: peerAgreeBytes,
    );
  }

  Future<bool> _fetchPeerIdentityOverTor() async {
    final resolved = await _identityResolver.fetchOverTor(
      onIdentityResolved: (identity) => peerIdentity = identity,
    );
    if (resolved == null) return false;
    peerIdentity = resolved.identity;
    peerPrekeyBundle = resolved.prekeyBundle;
    return true;
  }

  /// Retry pending 1:1 deliveries for one peer (wake-hint response).
  static Future<bool> processPendingForPeer({
    required String userId,
    required String peerId,
    required KeyManager keyManager,
  }) async {
    final chatPending = await PendingQueueReconciler.chatPendingForReceiver(
      senderId: userId,
      receiverId: peerId,
    );
    if (chatPending.isEmpty) return false;

    final service = ChatService(
      userId: userId,
      peerId: peerId,
      keyManager: keyManager,
    );
    final cached = await service._identityResolver.getCachedIdentityJson();
    if (cached != null) {
      service.peerIdentity = keyManager.importPeerIdentity(cached);
    } else {
      final ok = await service._fetchPeerIdentityOverTor();
      if (!ok) {
        service.dispose();
        return false;
      }
    }
    await service._processPendingOnce();
    service.dispose();
    return true;
  }

  /// Retry pending 1:1 deliveries for all peers (called from global sync timer).
  static Future<bool> processGlobalPending({
    required String userId,
    required KeyManager keyManager,
    int maxPerCycle = 20,
  }) async {
    final peerIds = await PendingQueueReconciler.peersWithPendingDirectMessages(
      senderId: userId,
      limit: maxPerCycle,
    );
    if (peerIds.isEmpty) return false;

    var anySuccess = false;
    for (final peer in peerIds) {
      final service = ChatService(
        userId: userId,
        peerId: peer,
        keyManager: keyManager,
      );
      final cached = await service._identityResolver.getCachedIdentityJson();
      if (cached != null) {
        service.peerIdentity = keyManager.importPeerIdentity(cached);
      } else {
        final ok = await service._fetchPeerIdentityOverTor();
        if (!ok) {
          service.dispose();
          continue;
        }
      }
      await service._processPendingOnce();
      anySuccess = true;
      service.dispose();
    }
    return anySuccess;
  }

  Future<void> _processPendingOnce() async {
    if (_isSending || _disposed) return;
    await reconcilePendingQueue();
    if (_isSending || _disposed) return;
    _isSending = true;
    try {
      await _reconciler.flushOnce();
    } finally {
      _isSending = false;
    }
  }

  Future<void> _markAsSent(String messageId) async {
    await MessagesDb.updateMessageStatus(messageId, 'sent');
    if (!_disposed) {
      _messageStatusController.add(MessageStatusUpdate(messageId, 'sent'));
    }
  }

  /// Re-queue a failed message for retry
  Future<void> resendMessage(
    String messageId, {
    bool processQueue = true,
  }) async {
    final rows = await MessagesDb.getMessageById(messageId);
    if (rows.isEmpty) return;
    final msg = rows.first;
    if (msg['deletedAt'] != null) {
      await PendingMessageDbHelper.removeOutboundPendingForWireId(messageId);
      return;
    }
    if (_cancelledSends.contains(messageId)) return;

    if (_inFlightSends.contains(messageId)) return;

    // Re-encrypt the stored self-payload for the peer
    // The message column has the self-encrypted payload, but we need
    // the peer-encrypted version. For text messages, re-encrypt from scratch.
    // For file messages, re-encrypt the stored data.
    if (peerIdentity == null) return;

    final type = msg['type'] as String;
    String peerPayload;

    if (type == 'text') {
      final plaintext =
          await keyManager.decryptMessage(msg['message'] as String);
      peerPayload = await keyManager.encryptForPeer(
        plaintext,
        peerIdentity!,
        peerId: peerId,
        peerPrekey: peerPrekeyBundle,
      );
    } else {
      final bytes = await CryptoWire.decryptFile(
        msg['message'] as String,
        keyManager.identity,
      );
      final payloads = await CryptoWire.encryptFile(
        bytes,
        keyManager.identity,
        peerIdentity!.agreePublic,
      );
      peerPayload = payloads.peerPayload;
    }

    // Update status back to pending
    final wasPending = (msg['status'] as String?) == 'pending';
    await MessagesDb.updateMessageStatus(messageId, 'pending');

    // Add to pending queue and process
    await _addToPendingQueue(
      messageId,
      peerPayload,
      type,
      replyToId: msg['replyTo'] as String?,
      fileName: msg['fileName'] as String?,
      fileSize: msg['fileSize'] as int?,
      viewOnce: (msg['viewOnce'] ?? 0) == 1,
      expiresAt: msg['expiresAt'] as int?,
      timestamp: msg['timestamp'] as int?,
    );

    if (!_disposed && !wasPending) {
      _messageStatusController.add(MessageStatusUpdate(messageId, 'pending'));
    }
    if (processQueue) {
      _processSendQueue();
    }
  }

  /// Cancel any future send attempt for [messageId] within this service.
  /// Already queued rows should still be removed by the caller; this only
  /// prevents in-flight sends started after the call from completing.
  void cancelPendingSend(String messageId) {
    _cancelledSends.add(messageId);
  }

  void _notifyPeerReachable() {
    lastSuccessfulActivity = DateTime.now();
    if (!_disposed) {
      _peerReachableController.add(true);
    }
  }

  Future<void> _addToPendingQueue(
    String id,
    String encrypted,
    String type, {
    String? replyToId,
    String? fileName,
    int? fileSize,
    bool viewOnce = false,
    int? expiresAt,
    int? timestamp,
  }) async {
    await PendingMessageDbHelper.insertPendingMessage({
      'id': id,
      'senderId': userId,
      'receiverId': peerId,
      'message': encrypted,
      'type': type,
      'fileName': fileName,
      'fileSize': fileSize,
      'timestamp': timestamp ?? DateTime.now().millisecondsSinceEpoch,
      'replyTo': replyToId,
      'viewOnce': viewOnce ? 1 : 0,
      'expiresAt': ?expiresAt,
    });
  }

}

class MessageStatusUpdate {
  final String messageId;
  final String status;
  MessageStatusUpdate(this.messageId, this.status);
}

/// Default [SideChannelPostman] wiring for [ChatService], delegating to the
/// existing [TransportProvider] singleton. Injected via the ctor so the
/// dependency is explicit and fake-able in tests; real callers keep going
/// through the app-wide transport until the composition root (Fase 5)
/// wires it explicitly.
class _ChatTransportPostman implements SideChannelPostman {
  const _ChatTransportPostman();

  @override
  Future<void> postDirect({
    required String peerId,
    required Map<String, dynamic> payload,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    await TransportProvider.postMessageOrFallback(
      peerOnion: peerId,
      payload: payload,
      timeout: timeout,
    );
  }

  @override
  Future<void> postGroup({
    required String targetMemberId,
    required Map<String, dynamic> payload,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    await TransportProvider.postMessageOrFallback(
      peerOnion: targetMemberId,
      payload: payload,
      timeout: timeout,
    );
  }
}
