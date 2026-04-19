import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:prysm/client/TorHttpClient.dart';
import 'package:prysm/database/messages.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/util/file_encrypt.dart';
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
  int _pollIntervalSeconds = 2;
  static const int _pollIntervalActive = 2;
  static const int _pollIntervalIdle = 5;
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
    if (peerPublicKeyPem != null) {
      peerPublicKey = keyManager.importPeerPublicKey(peerPublicKeyPem);
      return true;
    }

    // Try cache db first
    final cachedPem = await _getPeerPublicKeyFromDb();
    if (cachedPem != null) {
      peerPublicKey = keyManager.importPeerPublicKey(cachedPem);
      return true;
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
        _pollIntervalSeconds = hadNew ? _pollIntervalActive : _pollIntervalIdle;
      } catch (e) {
        print('Polling error: $e');
        _consecutivePollErrors++;
        // Exponential backoff: 2s, 4s, 8s, 16s, max 30s
        _pollIntervalSeconds = min(30, _pollIntervalActive * (1 << _consecutivePollErrors));
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

    // Only treat peer messages as proof of reachability if they're
    // very recent (just arrived via PrysmServer), not old DB messages
    // being read for the first time on chat open.
    final now = DateTime.now().millisecondsSinceEpoch;
    final hasFreshPeerMessage = newMessages.any(
      (msg) => msg['senderId'] == peerId &&
          (now - (msg['timestamp'] as int)).abs() < 15000,
    );
    if (hasFreshPeerMessage) {
      _notifyPeerReachable();
    }

    _newMessagesController.add(newMessages);
    return true;
  }

  static const int _maxRetries = 50;
  final Map<String, int> _retryCounts = {};

  Future<void> _processSendQueue() async {
    if (_isSending || _disposed) return;
    _isSending = true;

    int consecutiveFailures = 0;

    try {
      while (!_disposed) {
        final pending = await PendingMessageDbHelper.getPendingMessages();
        if (pending.isEmpty) break;

        final List<String> sentIds = [];
        bool hadFailure = false;

        for (final msg in pending) {
          if (_disposed) break;

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

        final remaining = await PendingMessageDbHelper.getPendingMessages();
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
    final isLargeMedia = type == 'file' || type == 'image' || type == 'audio';
    final timeout = isLargeMedia
        ? const Duration(minutes: 5)
        : const Duration(seconds: 30);

    // Try up to 2 times — Tor circuits are unreliable, a fresh circuit often works
    for (int attempt = 0; attempt < 2; attempt++) {
      final torClient = TorHttpClient(proxyHost: '127.0.0.1', proxyPort: 9050);
      try {
        final uri = Uri.parse('http://$peerId:80/message');
        final body = jsonEncode({
          "id": id,
          "senderId": userId,
          "receiverId": peerId,
          "message": encrypted,
          "type": type,
          "fileName": fileName,
          "fileSize": fileSize,
          "replyTo": replyToId,
          "viewOnce": viewOnce,
          "timestamp": DateTime.now().millisecondsSinceEpoch,
        });

        final response = await torClient
            .post(uri, {'Content-Type': 'application/json'}, body)
            .timeout(timeout);

        await response.transform(utf8.decoder).join();
        return true;
      } on TimeoutException {
        print('Send timeout for $type message (attempt ${attempt + 1})');
      } catch (e) {
        print('Send failed (attempt ${attempt + 1}): $e');
      } finally {
        torClient.close();
      }

      // Brief pause before retry with fresh circuit
      if (attempt == 0) {
        await Future.delayed(const Duration(seconds: 2));
      }
    }
    return false;
  }

  Future<bool> _fetchPeerPublicKeyOverTor() async {
    final torClient = TorHttpClient(proxyHost: '127.0.0.1', proxyPort: 9050);
    try {
      final uri = Uri.parse('http://$peerId:80/public');
      final response = await torClient.get(uri, {});
      final publicKeyPem = await response.transform(utf8.decoder).join();
      peerPublicKey = keyManager.importPeerPublicKey(publicKeyPem);
      return true;
    } catch (e) {
      print('Failed to fetch peer public key: $e');
      return false;
    } finally {
      torClient.close();
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
    await MessagesDb.setAsRead(messageId);

    // ✅ Only emit 'read' - UI already shows 'sent' optimistically
    if (!_disposed) {
      _messageStatusController.add(MessageStatusUpdate(messageId, 'read'));
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
