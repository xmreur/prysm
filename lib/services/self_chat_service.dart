import 'package:flutter/foundation.dart';
import 'package:flutter_chat_core/flutter_chat_core.dart';
import 'package:prysm/constants/media_constants.dart';
import 'package:prysm/crypto/wire.dart';
import 'package:prysm/database/self_messages_db.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/message_modify_policy.dart';
import 'package:uuid/uuid.dart';

class SelfChatService {
  SelfChatService({
    required this.userId,
    required this.keyManager,
  });

  final String userId;
  final KeyManager keyManager;

  Future<String> sendTextMessage(
    String text, {
    String? replyToId,
    String? messageId,
  }) async {
    final id = messageId ?? const Uuid().v4();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final encrypted = await keyManager.encryptForSelf(text);

    await SelfMessagesDb.insertMessage({
      'id': id,
      'message': encrypted,
      'type': 'text',
      'timestamp': timestamp,
      'replyTo': replyToId,
    });

    return id;
  }

  Future<String> sendFileMessage(
    Uint8List bytes,
    String fileName,
    String type, {
    String? replyToId,
    String? messageId,
    bool viewOnce = false,
  }) async {
    final id = messageId ?? const Uuid().v4();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final selfPub = await keyManager.identity.agreePublicKey;
    final encrypted = await CryptoWire.encryptFile(
      bytes,
      keyManager.identity,
      selfPub,
    );

    await SelfMessagesDb.insertMessage({
      'id': id,
      'message': encrypted.selfPayload,
      'type': type,
      'fileName': fileName,
      'fileSize': bytes.length,
      'timestamp': timestamp,
      'replyTo': replyToId,
      'viewOnce': viewOnce ? 1 : 0,
    });

    return id;
  }

  Future<List<Map<String, dynamic>>> loadMessagesBatch({
    int limit = 20,
    int? beforeTimestamp,
    String? beforeId,
  }) {
    return SelfMessagesDb.getMessagesBatch(
      limit: limit,
      beforeTimestamp: beforeTimestamp,
      beforeId: beforeId,
    );
  }

  Future<List<Message>> decryptMessages(
    List<Map<String, dynamic>> rawMessages,
  ) async {
    final messages = <Message>[];

    for (final msg in rawMessages) {
      final meta = metadataFromDbRow(msg);
      final wire = msg['message'];

      if (meta['deleted'] == true ||
          wire == null ||
          (wire is String && wire.isEmpty)) {
        messages.add(_deletedMessageFromRow(msg, meta));
        continue;
      }

      try {
        final type = msg['type'] as String? ?? 'text';
        final createdAt =
            DateTime.fromMillisecondsSinceEpoch(msg['timestamp'] as int);
        final id = msg['id'] as String;
        final replyTo = msg['replyTo'] as String?;

        switch (type) {
          case 'text':
            messages.add(
              TextMessage(
                authorId: userId,
                createdAt: createdAt,
                id: id,
                replyToMessageId: replyTo,
                text: await keyManager.decryptMessage(wire as String),
                metadata: meta.isEmpty ? null : meta,
              ),
            );
          case 'file':
            messages.add(
              FileMessage(
                id: id,
                authorId: userId,
                createdAt: createdAt,
                replyToMessageId: replyTo,
                name: msg['fileName'] as String? ?? 'Unknown',
                size: msg['fileSize'] as int? ?? 0,
                source: wire as String,
                metadata: meta.isEmpty ? null : meta,
              ),
            );
          case 'audio':
            messages.add(
              FileMessage(
                id: id,
                authorId: userId,
                createdAt: createdAt,
                replyToMessageId: replyTo,
                name: msg['fileName'] as String? ?? 'voice_message.wav',
                size: msg['fileSize'] as int? ?? 0,
                source: wire as String,
                metadata: meta.isEmpty ? null : meta,
              ),
            );
          case 'image':
            final isViewOnce = (msg['viewOnce'] ?? 0) == 1;
            final isViewed = (msg['viewed'] ?? 0) == 1;
            if (isViewOnce && isViewed) {
              messages.add(
                ImageMessage(
                  id: id,
                  authorId: userId,
                  createdAt: createdAt,
                  replyToMessageId: replyTo,
                  size: 0,
                  source: '',
                  metadata: const {'viewOnce': true, 'viewed': true},
                ),
              );
            } else {
              messages.add(
                ImageMessage(
                  id: id,
                  authorId: userId,
                  createdAt: createdAt,
                  replyToMessageId: replyTo,
                  size: msg['fileSize'] as int? ?? 0,
                  source: isViewOnce ? '' : deferredImageSourceFor(id),
                  metadata: isViewOnce
                      ? const {'viewOnce': true, 'viewed': false}
                      : (meta.isEmpty ? null : meta),
                ),
              );
            }
          default:
            messages.add(
              TextMessage(
                authorId: userId,
                createdAt: createdAt,
                id: id,
                text: 'Unsupported message type',
              ),
            );
        }
      } catch (e) {
        debugPrint('Self message decrypt failed (${msg['id']}): $e');
        messages.add(
          TextMessage(
            authorId: userId,
            createdAt:
                DateTime.fromMillisecondsSinceEpoch(msg['timestamp'] as int),
            id: msg['id'] as String,
            text: '🔒 Unable to decrypt message',
          ),
        );
      }
    }

    return messages;
  }

  Future<Uint8List> decryptFileFromRow(Map<String, dynamic> row) async {
    return CryptoWire.decryptFile(
      row['message'] as String,
      keyManager.identity,
    );
  }

  Future<Uint8List> decryptImageFromDb(String messageId) async {
    final rows = await SelfMessagesDb.getMessageById(messageId);
    if (rows.isEmpty) {
      throw StateError('Image message not found: $messageId');
    }
    return decryptFileFromRow(rows.first);
  }

  Message _deletedMessageFromRow(
    Map<String, dynamic> row,
    Map<String, Object?> meta,
  ) {
    return TextMessage(
      authorId: userId,
      createdAt: DateTime.fromMillisecondsSinceEpoch(row['timestamp'] as int),
      id: row['id'] as String,
      replyToMessageId: row['replyTo'] as String?,
      text: '',
      metadata: {...meta, 'deleted': true},
    );
  }
}
