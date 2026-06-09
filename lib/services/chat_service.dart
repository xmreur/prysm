import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:prysm/constants/group_constants.dart';
import 'package:prysm/client/TorHttpClient.dart';
import 'package:prysm/database/messages.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/util/file_encrypt.dart';
import 'package:prysm/util/battery_saver_policy.dart';
import 'package:prysm/util/tor_delivery.dart';
import 'package:prysm/util/tor_outbound_gateway.dart';
import 'package:prysm/util/tor_runtime_gate.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/pending_message_db_helper.dart';
import 'package:prysm/util/rsa_helper.dart';
import 'package:uuid/uuid.dart';
import 'package:pointycastle/asymmetric/api.dart';
import 'dart:math';

class ChatService {
  final String userId;
  final String peerId;
  final KeyManager keyManager;
  RSAPublicKey? peerPublicKey;

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

  ChatService({
    required this.userId,
    required this.peerId,
    required this.keyManager,
  });

  void dispose() {
    _disposed = true;
    _isPolling = false;
    _isSending = false;
    _newMessagesController.close();
    _messageStatusController.close();
    _peerReachableController.close();
  }

  // PUBLIC API

  Future<bool> initialize(String? peerPublicKeyPem) async {
    if (peerPublicKeyPem != null &&
        peerPublicKeyPem.isNotEmpty &&
        peerPublicKeyPem != 'NONE') {
      try {
        peerPublicKey = keyManager.importPeerPublicKey(peerPublicKeyPem);
        return true;
      } catch (e) {
        print('Invalid cached peer public key: $e');
      }
    }

    // Try cache db first
    final cachedPem = await _getPeerPublicKeyFromDb();
    if (cachedPem != null) {
      try {
        peerPublicKey = keyManager.importPeerPublicKey(cachedPem);
        return true;
      } catch (e) {
        print('Invalid peer public key in database: $e');
      }
    }
    return await _fetchPeerPublicKeyOverTor();
  }

  void startPolling() {
    if (_isPolling) return;
    _isPolling = true;
    _loopPoll();
  }

  void stopPolling() {
    _isPolling = false;
  }

  void startSendQueue() {
    _processSendQueue();
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
    if (peerPublicKey == null) return null;

    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final id =
        messageId ?? const Uuid().v4(); // ✅ Use provided ID or generate new

    final encryptedForPeer = keyManager.encryptForPeer(text, peerPublicKey!);
    final encryptedForSelf = keyManager.encryptForSelf(text);

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
    if (peerPublicKey == null) return null;

    final payload = await compute(_encryptFileIsolate, {
      'bytes': bytes,
      'peerPublicKey': peerPublicKey,
      'selfPublicKey': keyManager.publicKey,
    });

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
        _pollIntervalSeconds = hadNew
            ? BatterySaverPolicy.chatPollActiveSeconds()
            : BatterySaverPolicy.chatPollIdleSeconds();
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

  Future<bool> _fetchNewMessages() async {
    final batch = await MessagesDb.getMessagesBetweenBatch(
      userId,
      peerId,
      limit: 20,
      beforeTimestamp: null,
    );

    if (batch.isEmpty) return false;

    final newMessages = batch
        .where(
          (msg) =>
              _newestTimestamp == null ||
              (msg['timestamp'] as int) > _newestTimestamp!,
        )
        .toList();

    if (newMessages.isEmpty) return false;

    _newestTimestamp = newMessages
        .map((m) => m['timestamp'] as int)
        .reduce(max);

    // seedNewestTimestamp() prevents historical messages from counting; any
    // new peer-originated row here is live traffic.
    final hasNewPeerMessage =
        newMessages.any((msg) => msg['senderId'] == peerId);
    if (hasNewPeerMessage) {
      _notifyPeerReachable();
    }

    _newMessagesController.add(newMessages);
    return true;
  }

  static const int _maxRetries = 50;
  final Map<String, int> _retryCounts = {};

  Future<void> _processSendQueue() async {
    if (_isSending || _disposed || TorRuntimeGate.blocked) return;
    _isSending = true;

    int consecutiveFailures = 0;

    try {
      while (!_disposed) {
        final pending =
            await PendingMessageDbHelper.getPendingMessages(receiverId: peerId);
        if (pending.isEmpty) break;

        final List<String> sentIds = [];
        bool hadFailure = false;

        for (final msg in pending) {
          if (_disposed) break;

          final type = msg['type'] as String?;
          if (type != null && isSideChannelPendingType(type)) {
            continue;
          }

          final msgId = msg['id'] as String;
          final retries = _retryCounts[msgId] ?? 0;

          if (retries >= _maxRetries) {
            sentIds.add(msgId);
            _retryCounts.remove(msgId);
            if (!_disposed) {
              _messageStatusController.add(MessageStatusUpdate(msgId, 'failed'));
            }
            continue;
          }

          // If we already had a failure this batch, skip remaining
          // (peer is likely unreachable right now)
          if (hadFailure) break;

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
            sentIds.add(msgId);
            _retryCounts.remove(msgId);
            await _markAsSent(msgId);
            if (!_disposed) {
              _messageStatusController.add(MessageStatusUpdate(msgId, 'sent'));
            }
            consecutiveFailures = 0;
            _notifyPeerReachable();
          } else {
            _retryCounts[msgId] = retries + 1;
            consecutiveFailures++;
            hadFailure = true;
          }
        }

        if (sentIds.isNotEmpty) {
          await PendingMessageDbHelper.removeMessages(sentIds);
        }

        final remaining =
            await PendingMessageDbHelper.getPendingMessages(receiverId: peerId);
        if (remaining.isEmpty) break;

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
    if (TorRuntimeGate.blocked) return false;

    final isLargeMedia = type == 'file' || type == 'image' || type == 'audio';
    final timeout = isLargeMedia
        ? const Duration(minutes: 5)
        : const Duration(seconds: 30);

    try {
      if (TorOutboundGateway.isConfigured) {
        await TorOutboundGateway.instance.postMessage(
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
      }

      return await TorDelivery.withTorRetry<bool>(
        attempt: () => _postOverTorOnce(
          id: id,
          encrypted: encrypted,
          type: type,
          replyToId: replyToId,
          fileName: fileName,
          fileSize: fileSize,
          viewOnce: viewOnce,
          timeout: timeout,
        ),
      );
    } on TimeoutException {
      print('Send timeout for $type message');
      return false;
    } catch (e) {
      debugPrint('Send deferred (queued for retry): $e');
      return false;
    }
  }

  Future<bool> _postOverTorOnce({
    required String id,
    required String encrypted,
    required String type,
    String? replyToId,
    String? fileName,
    int? fileSize,
    bool viewOnce = false,
    required Duration timeout,
  }) async {
    final torClient = TorHttpClient(proxyHost: '127.0.0.1', proxyPort: 9050);
    try {
      final uri = Uri.parse('http://$peerId:80/message');
      final body = jsonEncode({
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
      });

      final response = await torClient
          .post(uri, {'Content-Type': 'application/json'}, body)
          .timeout(timeout);

      await torClient.readUtf8Body(response);
      return true;
    } finally {
      torClient.close();
    }
  }

  Future<bool> _fetchPeerPublicKeyOverTor() async {
    if (TorRuntimeGate.blocked) return false;
    try {
      final publicKeyPem = TorOutboundGateway.isConfigured
          ? (await TorOutboundGateway.instance.getPublic(peerId)).trim()
          : await TorDelivery.withTorRetry<String>(
              attempt: () async {
                final torClient =
                    TorHttpClient(proxyHost: '127.0.0.1', proxyPort: 9050);
                try {
                  final uri = Uri.parse('http://$peerId:80/public');
                  final response = await torClient.get(uri, {});
                  return (await torClient.readUtf8Body(response)).trim();
                } finally {
                  torClient.close();
                }
              },
            );
      peerPublicKey = keyManager.importPeerPublicKey(publicKeyPem);
      await _persistPeerPublicKey(publicKeyPem);
      return true;
    } catch (e) {
      print('Failed to fetch peer public key: $e');
      return false;
    }
  }

  Future<void> _persistPeerPublicKey(String publicKeyPem) async {
    try {
      final existing = await DBHelper.getUserById(peerId);
      await DBHelper.insertOrUpdateUser({
        'id': peerId,
        'name': existing?['name'] ?? peerId,
        'avatarUrl': existing?['avatarUrl'] ?? '',
        'avatarBase64': existing?['avatarBase64'],
        'customName': existing?['customName'],
        'publicKeyPem': publicKeyPem,
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
    final cached = await service._getPeerPublicKeyFromDb();
    if (cached != null) {
      service.peerPublicKey = keyManager.importPeerPublicKey(cached);
    } else {
      final ok = await service._fetchPeerPublicKeyOverTor();
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
      final cached = await service._getPeerPublicKeyFromDb();
      if (cached != null) {
        service.peerPublicKey = keyManager.importPeerPublicKey(cached);
      } else {
        final ok = await service._fetchPeerPublicKeyOverTor();
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
    _isSending = true;
    try {
      final pending =
          await PendingMessageDbHelper.getPendingMessages(receiverId: peerId);
      if (pending.isEmpty || peerPublicKey == null) return;

      final sentIds = <String>[];
      for (final msg in pending.take(10)) {
        if (_disposed) break;
        final type = msg['type'] as String?;
        if (type != null && isSideChannelPendingType(type)) {
          continue;
        }
        final msgId = msg['id'] as String;
        final success = await _sendOverTor(
          msgId,
          msg['message'] as String,
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

  Future<String?> _getPeerPublicKeyFromDb() async {
    try {
      final user = await DBHelper.getUserById(peerId);
      return user!['publicKeyPem'] as String?;
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
  Future<void> resendMessage(String messageId) async {
    final rows = await MessagesDb.getMessageById(messageId);
    if (rows.isEmpty) return;
    final msg = rows.first;

    // Re-encrypt the stored self-payload for the peer
    // The message column has the self-encrypted payload, but we need
    // the peer-encrypted version. For text messages, re-encrypt from scratch.
    // For file messages, re-encrypt the stored data.
    if (peerPublicKey == null) return;

    final type = msg['type'] as String;
    String peerPayload;

    if (type == 'text') {
      // Decrypt our copy, re-encrypt for peer
      final plaintext = keyManager.decryptMessage(msg['message'] as String);
      peerPayload = keyManager.encryptForPeer(plaintext, peerPublicKey!);
    } else {
      // For files/images/audio: decrypt self payload, re-encrypt for peer
      final selfPayloadJson = jsonDecode(msg['message'] as String) as Map<String, dynamic>;
      final selfKey = keyManager.privateKey;
      final aesKeyBytes = RSAHelper.decryptBytesWithPrivateKey(
        base64Decode(selfPayloadJson['aes_key'] as String), selfKey);
      // Re-encrypt AES key for peer
      final peerEncryptedKey = RSAHelper.encryptBytesWithPublicKey(aesKeyBytes, peerPublicKey!);
      peerPayload = jsonEncode({
        'aes_key': peerEncryptedKey,
        'iv': selfPayloadJson['iv'],
        'data': selfPayloadJson['data'],
      });
    }

    // Update status back to pending
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

    if (!_disposed) {
      _messageStatusController.add(MessageStatusUpdate(messageId, 'pending'));
    }
    _processSendQueue();
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

  static Map<String, String> _encryptFileIsolate(Map<String, dynamic> params) {
    final bytes = params['bytes'] as Uint8List;
    final peerPubKey = params['peerPublicKey'] as RSAPublicKey;
    final selfPubKey = params['selfPublicKey'] as RSAPublicKey;

    final aesKey = AESHelper.generateAESKey();
    final iv = AESHelper.generateIV();
    final encryptedBytes = AESHelper.encryptBytes(bytes, aesKey, iv);

    final peerEncryptedKey = RSAHelper.encryptBytesWithPublicKey(
      aesKey.bytes,
      peerPubKey,
    );
    final selfEncryptedKey = RSAHelper.encryptBytesWithPublicKey(
      aesKey.bytes,
      selfPubKey,
    );

    return {
      'peerPayload': jsonEncode({
        'aes_key': peerEncryptedKey,
        'iv': iv.base64,
        'data': base64Encode(encryptedBytes),
      }),
      'selfPayload': jsonEncode({
        'aes_key': selfEncryptedKey,
        'iv': iv.base64,
        'data': base64Encode(encryptedBytes),
      }),
    };
  }
}

class MessageStatusUpdate {
  final String messageId;
  final String status;
  MessageStatusUpdate(this.messageId, this.status);
}
