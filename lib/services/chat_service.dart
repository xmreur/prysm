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

  final _newMessagesController =
      StreamController<List<Map<String, dynamic>>>.broadcast();
  final _messageStatusController =
      StreamController<MessageStatusUpdate>.broadcast();

  Stream<List<Map<String, dynamic>>> get onNewMessages =>
      _newMessagesController.stream;
  Stream<MessageStatusUpdate> get onMessageStatus =>
      _messageStatusController.stream;

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
    String? messageId, // ✅ Add messageId parameter
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
    });

    final success = await _sendOverTor(
      id,
      payload['peerPayload']!,
      type,
      fileName: fileName,
      fileSize: bytes.length,
      replyToId: replyToId,
    );

    if (success) {
      await _markAsSent(id);
    } else {
      await _addToPendingQueue(
        id,
        payload['peerPayload']!,
        type,
        fileName: fileName,
        fileSize: bytes.length,
        replyToId: replyToId,
      );
    }

    return id;
  }

  // Private methods

  Future<void> _loopPoll() async {
    while (_isPolling && !_disposed) {
      try {
        await _fetchNewMessages();
      } catch (e) {
        print('Polling error: $e');
      }

      if (_isPolling && !_disposed) {
        await Future.delayed(const Duration(seconds: 2));
      }
    }
  }

  Future<void> _fetchNewMessages() async {
    final batch = await MessagesDb.getMessagesBetweenBatch(
      userId,
      peerId,
      limit: 20,
      beforeTimestamp: null,
    );

    if (batch.isEmpty) return;

    final newMessages = batch
        .where(
          (msg) =>
              _newestTimestamp == null ||
              (msg['timestamp'] as int) > _newestTimestamp!,
        )
        .toList();

    if (newMessages.isEmpty) return;

    _newestTimestamp = newMessages
        .map((m) => m['timestamp'] as int)
        .reduce(max);
    _newMessagesController.add(newMessages);
  }

  Future<void> _processSendQueue() async {
    if (_isSending || _disposed) return;
    _isSending = true;

    try {
      while (!_disposed) {
        final pending = await PendingMessageDbHelper.getPendingMessages();
        if (pending.isEmpty) break;

        for (final msg in pending) {
          if (_disposed) break;

          final success = await _sendOverTor(
            msg['id'],
            msg['message'],
            msg['type'],
            replyToId: msg['replyTo'],
            fileName: msg['fileName'],
            fileSize: msg['fileSize'],
          );

          if (success) {
            await PendingMessageDbHelper.removeMessage(msg['id']);
            await _markAsSent(msg['id']);
            _messageStatusController.add(
              MessageStatusUpdate(msg['id'], 'sent'),
            );
          } else {
            // Wait before retrying
            await Future.delayed(const Duration(seconds: 10));
            break; // Try again later
          }
        }

        // if still pending
        final remaining = await PendingMessageDbHelper.getPendingMessages();

        if (remaining.isEmpty) break;
        await Future.delayed(const Duration(seconds: 15));
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
  }) async {
    final isLargeMedia = type == 'file' || type == 'image';
    final timeout = isLargeMedia
        ? const Duration(minutes: 5)
        : const Duration(seconds: 30);

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
        "timestamp": DateTime.now().millisecondsSinceEpoch,
      });

      final response = await torClient
          .post(uri, {'Content-Type': 'application/json'}, body)
          .timeout(timeout);

      await response.transform(utf8.decoder).join();
      return true;
    } on TimeoutException {
      print('Send timeout for $type message');
      return false;
    } catch (e) {
      print('Send failed: $e');
      return false;
    } finally {
      torClient.close();
    }
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

  Future<void> _addToPendingQueue(
    String id,
    String encrypted,
    String type, {
    String? replyToId,
    String? fileName,
    int? fileSize,
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
