
import 'package:prysm/models/chat/prysm_message.dart';
import 'package:prysm/constants/media_constants.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/message_modify_policy.dart';
import 'package:prysm/util/logging.dart';

/// Decrypts direct-chat DB rows using the main window's unlocked [KeyManager].
class DirectChatMessageDecrypt {
  DirectChatMessageDecrypt._();

  static Future<String> decryptDirectTextMessage(
    Map<String, dynamic> msg,
    String userId,
    KeyManager keyManager,
  ) async {
    final senderId = msg['senderId'] as String;
    final wire = msg['message'] as String?;
    if (wire == null || wire.isEmpty) {
      throw const FormatException('Empty message payload');
    }

    if (senderId == userId) {
      return keyManager.decryptMessage(wire);
    }

    final user = await DBHelper.getUserById(senderId);
    final identityJson =
        (user?['identityJson'] as String?) ?? (user?['publicKeyPem'] as String?);
    if (identityJson == null || identityJson.isEmpty) {
      throw const FormatException('Missing peer identity');
    }
    final peerKey = keyManager.importPeerIdentity(identityJson);
    return keyManager.decryptPeerMessage(
      peerId: senderId,
      wire: wire,
      peer: peerKey,
    );
  }

  static Future<List<Message>> decryptMessages(
    List<Map<String, dynamic>> rawMessages,
    String userId,
    KeyManager keyManager,
  ) async {
    final messages = <Message>[];

    for (final msg in rawMessages) {
      final meta = metadataFromDbRow(msg);
      final wire = msg['message'];
      if (meta['deleted'] == true ||
          wire == null ||
          (wire is String && wire.isEmpty)) {
        messages.add(
          TextMessage(
            authorId: msg['senderId'] as String,
            createdAt: DateTime.fromMillisecondsSinceEpoch(msg['timestamp'] as int),
            id: msg['id'] as String,
            replyToMessageId: msg['replyTo'] as String?,
            text: '',
            metadata: meta,
          ),
        );
        continue;
      }

      try {
        final type = msg['type'] as String? ?? 'text';
        if (type == 'text') {
          messages.add(
            TextMessage(
              authorId: msg['senderId'] as String,
              createdAt: DateTime.fromMillisecondsSinceEpoch(msg['timestamp'] as int),
              id: msg['id'] as String,
              replyToMessageId: msg['replyTo'] as String?,
              text: await decryptDirectTextMessage(msg, userId, keyManager),
              metadata: meta.isEmpty ? null : meta,
            ),
          );
        } else if (type == 'file' || type == 'audio') {
          messages.add(
            FileMessage(
              id: msg['id'] as String,
              authorId: msg['senderId'] as String,
              createdAt: DateTime.fromMillisecondsSinceEpoch(msg['timestamp'] as int),
              replyToMessageId: msg['replyTo'] as String?,
              name: msg['fileName'] as String? ?? 'file',
              size: (msg['fileSize'] as num?)?.toInt() ?? 0,
              source: msg['message'] as String,
              metadata: meta.isEmpty ? null : meta,
            ),
          );
        } else if (type == 'image') {
          final isViewOnce = (msg['viewOnce'] ?? 0) == 1;
          final isViewed = (msg['viewed'] ?? 0) == 1;
          if (isViewOnce && isViewed) {
            messages.add(
              ImageMessage(
                id: msg['id'] as String,
                authorId: msg['senderId'] as String,
                createdAt: DateTime.fromMillisecondsSinceEpoch(msg['timestamp'] as int),
                replyToMessageId: msg['replyTo'] as String?,
                size: 0,
                source: '',
                metadata: const {'viewOnce': true, 'viewed': true},
              ),
            );
          } else {
            messages.add(
              ImageMessage(
                id: msg['id'] as String,
                authorId: msg['senderId'] as String,
                createdAt: DateTime.fromMillisecondsSinceEpoch(msg['timestamp'] as int),
                replyToMessageId: msg['replyTo'] as String?,
                size: (msg['fileSize'] as num?)?.toInt() ?? 0,
                source: isViewOnce ? '' : deferredImageSourceFor(msg['id'] as String),
                metadata: isViewOnce
                    ? const {'viewOnce': true, 'viewed': false}
                    : (meta.isEmpty ? null : meta),
              ),
            );
          }
        }
      } catch (e) {
        Logging.error('Direct message decrypt failed (${msg['id']}): $e', 'DirectChatMessageDecrypt');
        messages.add(
          TextMessage(
            authorId: msg['senderId'] as String,
            createdAt: DateTime.fromMillisecondsSinceEpoch(msg['timestamp'] as int),
            id: msg['id'] as String,
            replyToMessageId: msg['replyTo'] as String?,
            text: '🔒 Unable to decrypt message',
          ),
        );
      }
    }

    return messages;
  }
}
