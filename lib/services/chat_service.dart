import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:prysm/constants/group_constants.dart';
import 'package:prysm/crypto/crypto.dart';
import 'package:prysm/database/messages.dart';
import 'package:prysm/transport/transport_provider.dart';
import 'package:prysm/services/block_service.dart';
import 'package:prysm/util/battery_saver_policy.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/util/inbound_message_notifier.dart';
import 'package:prysm/util/key_manager.dart';
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

  ChatService({
    required this.userId,
    required this.peerId,
    required this.keyManager,
  });

  void dispose() {
    _disposed = true;
    _isPolling = false;
    _isSending = false;
    _inboundSub?.cancel();
    _inboundSub = null;
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
        print('Invalid cached peer identity: $e');
      }
    }

    final cached = await _getPeerIdentityFromDb();
    if (cached != null) {
      try {
        peerIdentity = keyManager.importPeerIdentity(cached);
        return true;
      } catch (e) {
        print('Invalid peer identity in database: $e');
      }
    }
    return await _fetchPeerIdentityOverTor();
  }

  void startPolling() {
    if (_isPolling) return;
    _isPolling = true;
    _subscribeInbound();
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

  void stopPolling() {
    _isPolling = false;
  }

  void startSendQueue() {
    unawaited(reconcilePendingQueue().whenComplete(_processSendQueue));
  }

  /// Re-queues outbound messages that show as pending in the UI but were
  /// dropped from the pending_messages retry table (e.g. after a failed send
  /// before the queue insert, or app restart during a long Tor timeout).
  Future<void> reconcilePendingQueue() async {
    if (_disposed || peerIdentity == null) return;

    final pendingRows = await MessagesDb.getPendingOutboundDirectMessages(
      senderId: userId,
      receiverId: peerId,
    );
    if (pendingRows.isEmpty) return;

    for (final row in pendingRows) {
      if (_disposed || peerIdentity == null) return;

      final wireId = MessagesDb.wireIdFromStorage(row['id'] as String);
      final type = row['type'] as String? ?? 'text';
      if (isSideChannelPendingType(type)) continue;
      if (_inFlightSends.contains(wireId)) continue;

      final queued =
          await PendingMessageDbHelper.getPendingOutboundForWireId(wireId);
      if (queued != null) continue;

      try {
        await resendMessage(wireId, processQueue: false);
      } catch (e) {
        debugPrint('Failed to re-queue pending message $wireId: $e');
      }
    }
  }

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
    });

    final success = await _sendOverTor(
      id,
      encryptedForPeer,
      'text',
      replyToId: replyToId,
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

    final payload = await _encryptFilePayload(bytes);

    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final id =
        messageId ?? const Uuid().v4(); // ✅ Use provided ID or generate new

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
    });

    final success = await _sendOverTor(
      id,
      payload['peerPayload']!,
      type,
      fileName: fileName,
      fileSize: bytes.length,
      replyToId: replyToId,
      viewOnce: viewOnce,
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
        payload['peerPayload']!,
        type,
        fileName: fileName,
        fileSize: bytes.length,
        replyToId: replyToId,
        viewOnce: viewOnce,
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
        print('Polling error: $e');
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

  Future<bool> _sendOverTor(
    String id,
    String encrypted,
    String type, {
    String? replyToId,
    String? fileName,
    int? fileSize,
    bool viewOnce = false,
  }) async {
    if (BlockService.instance.isBlocked(peerId)) return false;
    if (TorRuntimeGate.blocked) return false;

    final isLargeMedia = type == 'file' || type == 'image' || type == 'audio';
    final timeout = isLargeMedia
        ? const Duration(minutes: 5)
        : const Duration(seconds: 30);

    try {
      _inFlightSends.add(id);
      await TransportProvider.postMessageOrFallback(
        peerOnion: peerId,
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
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        },
        timeout: timeout,
      );
      return true;
    } on TimeoutException {
      print('Send timeout for $type message');
      return false;
    } catch (e) {
      debugPrint('Send deferred (queued for retry): $e');
      return false;
    } finally {
      _inFlightSends.remove(id);
    }
  }

  Future<Map<String, String>> _encryptFilePayload(Uint8List bytes) async {
    final peer = peerIdentity!;
    final result = await CryptoWire.encryptFile(
      bytes,
      keyManager.identity,
      peer.agreePublic,
    );
    return {
      'peerPayload': result.peerPayload,
      'selfPayload': result.selfPayload,
    };
  }

  Future<bool> _fetchPeerIdentityOverTor() async {
    if (TorRuntimeGate.blocked) return false;
    try {
      String? identityJson;
      try {
        final profileBody =
            await TransportProvider.getProfileOrFallback(peerId);
        final data = jsonDecode(profileBody) as Map<String, dynamic>;
        identityJson = (data['identityJson'] as String?)?.trim() ??
            (data['publicKeyPem'] as String?)?.trim();
        final prekeyRaw = data['prekeyBundle'];
        peerIdentity = keyManager.importPeerIdentity(identityJson!);
        if (prekeyRaw is Map) {
          peerPrekeyBundle = await PrekeyBundle.parseVerified(
            Map<String, dynamic>.from(prekeyRaw),
            peerIdentity!,
          );
        }
      } catch (_) {
        identityJson =
            (await TransportProvider.getPublicOrFallback(peerId)).trim();
        peerIdentity = keyManager.importPeerIdentity(identityJson);
      }
      await _persistPeerIdentity(identityJson);
      return true;
    } catch (e) {
      print('Failed to fetch peer identity: $e');
      return false;
    }
  }

  Future<void> _persistPeerIdentity(String identityJson) async {
    try {
      final existing = await DBHelper.getUserById(peerId);
      await DBHelper.insertOrUpdateUser({
        'id': peerId,
        'name': existing?['name'] ?? peerId,
        'avatarUrl': existing?['avatarUrl'] ?? '',
        'avatarBase64': existing?['avatarBase64'],
        'customName': existing?['customName'],
        'identityJson': identityJson,
        'publicKeyPem': identityJson,
      });
    } catch (e) {
      print('Failed to persist peer public key: $e');
    }
  }

  /// Retry pending 1:1 deliveries for one peer (wake-hint response).
  static Future<bool> processPendingForPeer({
    required String userId,
    required String peerId,
    required KeyManager keyManager,
  }) async {
    final pending = await PendingMessageDbHelper.getPendingDirectMessagesForReceiver(
      senderId: userId,
      receiverId: peerId,
    );
    final chatPending = pending.where((m) {
      final type = m['type'] as String?;
      if (type == null) return false;
      return !isReadReceiptType(type) &&
          !isReactionType(type) &&
          !isMessageModifyType(type);
    }).toList();
    if (chatPending.isEmpty) return false;

    final service = ChatService(
      userId: userId,
      peerId: peerId,
      keyManager: keyManager,
    );
    final cached = await service._getPeerIdentityFromDb();
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
    final pending = await PendingMessageDbHelper.getPendingDirectMessages(
      senderId: userId,
      limit: maxPerCycle,
    );
    if (pending.isEmpty) return false;

    final peerIds = pending
        .map((m) => m['receiverId'] as String?)
        .whereType<String>()
        .where((id) => id.isNotEmpty)
        .toSet();

    var anySuccess = false;
    for (final peer in peerIds) {
      final service = ChatService(
        userId: userId,
        peerId: peer,
        keyManager: keyManager,
      );
      final cached = await service._getPeerIdentityFromDb();
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
      final pending =
          await PendingMessageDbHelper.getPendingMessages(receiverId: peerId);
      if (pending.isEmpty || peerIdentity == null) return;

      final sentIds = <String>[];
      for (final msg in pending.take(10)) {
        if (_disposed) break;
        final type = msg['type'] as String?;
        if (type != null && isSideChannelPendingType(type)) {
          continue;
        }
        final msgId = msg['id'] as String;
        final stored = await MessagesDb.getMessageById(msgId);
        if (stored.isEmpty || stored.first['deletedAt'] != null) {
          await PendingMessageDbHelper.removeOutboundPendingForWireId(msgId);
          continue;
        }
        final encrypted = msg['message'] as String?;
        if (encrypted == null || encrypted.isEmpty) {
          await PendingMessageDbHelper.removeOutboundPendingForWireId(msgId);
          continue;
        }
        final success = await _sendOverTor(
          msgId,
          encrypted,
          msg['type'] as String,
          replyToId: msg['replyTo'] as String?,
          fileName: msg['fileName'] as String?,
          fileSize: msg['fileSize'] as int?,
          viewOnce: (msg['viewOnce'] ?? 0) == 1,
        );
        if (success) {
          sentIds.add(msgId);
          await _markAsSent(msgId);
        } else {
          break;
        }
      }
      if (sentIds.isNotEmpty) {
        await PendingMessageDbHelper.removeMessages(sentIds);
      }
    } finally {
      _isSending = false;
    }
  }

  Future<String?> _getPeerIdentityFromDb() async {
    try {
      final user = await DBHelper.getUserById(peerId);
      return (user?['identityJson'] as String?) ??
          (user?['publicKeyPem'] as String?);
    } catch (_) {
      return null;
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
  }) async {
    await PendingMessageDbHelper.insertPendingMessage({
      'id': id,
      'senderId': userId,
      'receiverId': peerId,
      'message': encrypted,
      'type': type,
      'fileName': fileName,
      'fileSize': fileSize,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'replyTo': replyToId,
      'viewOnce': viewOnce ? 1 : 0,
    });
  }

}

class MessageStatusUpdate {
  final String messageId;
  final String status;
  MessageStatusUpdate(this.messageId, this.status);
}
