import 'dart:typed_data';

import 'package:flutter_chat_core/flutter_chat_core.dart';
import 'package:prysm/constants/group_constants.dart';
import 'package:prysm/database/messages.dart';
import 'package:prysm/models/contact.dart';
import 'package:prysm/models/detached_chat_launch.dart';
import 'package:prysm/models/group.dart';
import 'package:prysm/services/chat_service.dart';
import 'package:prysm/services/detached_chat_host.dart';
import 'package:prysm/services/group_chat_service.dart';
import 'package:prysm/services/group_service.dart';
import 'package:prysm/services/self_chat_service.dart';
import 'package:prysm/util/direct_chat_message_decrypt.dart';
import 'package:prysm/util/group_crypto.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/message_modify_policy.dart';
import 'package:prysm/constants/media_constants.dart';

/// Wires [DetachedChatHost] to Prysm services in the main window.
class DetachedChatBridge {
  DetachedChatBridge._();

  static Future<void> _notifyStatus({
    required DetachedChatKind chatKind,
    required String conversationId,
    required String messageId,
    required String status,
  }) {
    return DetachedChatHost.instance.forwardMessageStatus(
      kind: chatKind,
      conversationId: conversationId,
      messageId: messageId,
      status: status,
    );
  }

  static void configure({
    required KeyManager keyManager,
    required String userId,
    required Contact Function() appUser,
    required List<Contact> Function() contacts,
    required Group? Function(String groupId) groupById,
  }) {
    final host = DetachedChatHost.instance;
    host.decryptRows = (kind, conversationId, rows) {
      return _decryptRows(
        kind: kind,
        conversationId: conversationId,
        rows: rows,
        userId: userId,
        keyManager: keyManager,
        groupById: groupById,
      );
    };
    host.sendText = ({
      required chatKind,
      required conversationId,
      required text,
      replyToId,
      required messageId,
    }) {
      return _sendText(
        chatKind: chatKind,
        conversationId: conversationId,
        text: text,
        replyToId: replyToId,
        messageId: messageId,
        userId: userId,
        keyManager: keyManager,
        contacts: contacts(),
        groupById: groupById,
      );
    };
    host.sendFile = ({
      required chatKind,
      required conversationId,
      required bytes,
      required fileName,
      required type,
      replyToId,
      required messageId,
      viewOnce = false,
    }) {
      return _sendFile(
        chatKind: chatKind,
        conversationId: conversationId,
        bytes: bytes,
        fileName: fileName,
        type: type,
        replyToId: replyToId,
        messageId: messageId,
        viewOnce: viewOnce,
        userId: userId,
        keyManager: keyManager,
        contacts: contacts(),
        groupById: groupById,
      );
    };
    host.sendVoice = ({
      required chatKind,
      required conversationId,
      required bytes,
      required durationMs,
      required messageId,
    }) {
      return _sendFile(
        chatKind: chatKind,
        conversationId: conversationId,
        bytes: bytes,
        fileName: 'voice_message.wav',
        type: 'audio',
        messageId: messageId,
        userId: userId,
        keyManager: keyManager,
        contacts: contacts(),
        groupById: groupById,
      );
    };
  }

  static Future<List<Message>> _decryptRows({
    required DetachedChatKind kind,
    required String conversationId,
    required List<Map<String, dynamic>> rows,
    required String userId,
    required KeyManager keyManager,
    required Group? Function(String groupId) groupById,
  }) async {
    switch (kind) {
      case DetachedChatKind.direct:
        return DirectChatMessageDecrypt.decryptMessages(rows, userId, keyManager);
      case DetachedChatKind.self:
        return SelfChatService(userId: userId, keyManager: keyManager)
            .decryptMessages(rows);
      case DetachedChatKind.group:
        return _decryptGroupRows(
          groupId: conversationId,
          rows: rows,
          userId: userId,
          keyManager: keyManager,
          groupById: groupById,
        );
    }
  }

  static Future<List<Message>> _decryptGroupRows({
    required String groupId,
    required List<Map<String, dynamic>> rows,
    required String userId,
    required KeyManager keyManager,
    required Group? Function(String groupId) groupById,
  }) async {
    final groupService = GroupService(keyManager: keyManager, userId: userId);
    final groupKey = await groupService.getDecryptedGroupKey(groupId);
    if (groupKey == null) return [];

    final result = <Message>[];
    for (final msg in rows) {
      try {
        final type = msg['type'] as String;
        final authorId = msg['senderId'] as String;
        final createdAt =
            DateTime.fromMillisecondsSinceEpoch(msg['timestamp'] as int);
        final id = MessagesDb.wireIdFromStorage(msg['id'] as String);
        final replyTo = msg['replyTo'] as String?;
        final meta = metadataFromDbRow(msg);
        final wire = msg['message'];

        if (meta['deleted'] == true ||
            wire == null ||
            (wire is String && wire.isEmpty)) {
          result.add(
            TextMessage(
              authorId: authorId,
              createdAt: createdAt,
              id: id,
              replyToMessageId: replyTo,
              text: '',
              metadata: {...meta, 'deleted': true},
            ),
          );
          continue;
        }

        if (type == groupTextType) {
          final wireStr = wire as String;
          final text = GroupCrypto.isSenderKeyEnvelope(wireStr)
              ? await GroupCrypto.decryptWithSenderKey(
                  epochKey: groupKey,
                  groupId: groupId,
                  wire: wireStr,
                  transportSenderId: authorId,
                  keyManager: keyManager,
                )
              : await GroupCrypto.decryptText(groupKey, wireStr);
          result.add(
            TextMessage(
              authorId: authorId,
              createdAt: createdAt,
              id: id,
              text: text,
              replyToMessageId: replyTo,
              metadata: meta.isEmpty ? null : meta,
            ),
          );
        } else if (type == groupImageType) {
          final isViewOnce = (msg['viewOnce'] ?? 0) == 1;
          final isViewed = (msg['viewed'] ?? 0) == 1;
          result.add(
            ImageMessage(
              id: id,
              authorId: authorId,
              createdAt: createdAt,
              replyToMessageId: replyTo,
              size: (msg['fileSize'] as num?)?.toInt() ?? 0,
              source: isViewOnce || isViewed ? '' : deferredImageSourceFor(id),
              metadata: isViewOnce
                  ? {'viewOnce': true, 'viewed': isViewed}
                  : (meta.isEmpty ? null : meta),
            ),
          );
        } else if (type == groupFileType || type == groupAudioType) {
          final fileName = msg['fileName'] as String? ??
              (type == groupAudioType ? 'voice_message.wav' : 'file');
          result.add(
            FileMessage(
              id: id,
              authorId: authorId,
              createdAt: createdAt,
              replyToMessageId: replyTo,
              name: fileName,
              size: (msg['fileSize'] as num?)?.toInt() ?? 0,
              source: wire as String,
              metadata: meta.isEmpty ? null : meta,
            ),
          );
        }
      } catch (_) {
        result.add(
          TextMessage(
            authorId: msg['senderId'] as String,
            createdAt: DateTime.fromMillisecondsSinceEpoch(msg['timestamp'] as int),
            id: MessagesDb.wireIdFromStorage(msg['id'] as String),
            text: 'Unable to decrypt message',
            metadata: const {'decryptFailed': true},
          ),
        );
      }
    }
    return result;
  }

  static Future<String?> _sendText({
    required DetachedChatKind chatKind,
    required String conversationId,
    required String text,
    String? replyToId,
    required String messageId,
    required String userId,
    required KeyManager keyManager,
    required List<Contact> contacts,
    required Group? Function(String groupId) groupById,
  }) async {
    switch (chatKind) {
      case DetachedChatKind.direct:
        Contact? contact;
        for (final c in contacts) {
          if (c.id == conversationId) {
            contact = c;
            break;
          }
        }
        final service = ChatService(
          userId: userId,
          peerId: conversationId,
          keyManager: keyManager,
        );
        await service.initialize(contact?.publicKeyPem);
        final id = await service.sendTextMessage(
          text,
          replyToId: replyToId,
          messageId: messageId,
        );
        service.dispose();
        if (id != null) {
          await _notifyStatus(
            chatKind: chatKind,
            conversationId: conversationId,
            messageId: messageId,
            status: 'sent',
          );
        }
        return id;
      case DetachedChatKind.self:
        final id = await SelfChatService(userId: userId, keyManager: keyManager)
            .sendTextMessage(text, replyToId: replyToId, messageId: messageId);
        await _notifyStatus(
          chatKind: chatKind,
          conversationId: conversationId,
          messageId: messageId,
          status: 'sent',
        );
        return id;
      case DetachedChatKind.group:
        final group = groupById(conversationId);
        if (group == null) return null;
        final groupService = GroupService(keyManager: keyManager, userId: userId);
        final chatService = GroupChatService(
          userId: userId,
          groupId: conversationId,
          keyManager: keyManager,
          groupService: groupService,
        );
        await chatService.initialize();
        final id = await chatService.sendTextMessage(
          text,
          replyToId: replyToId,
          messageId: messageId,
        );
        chatService.dispose();
        if (id != null) {
          await _notifyStatus(
            chatKind: chatKind,
            conversationId: conversationId,
            messageId: messageId,
            status: 'sent',
          );
        }
        return id;
    }
  }

  static Future<String?> _sendFile({
    required DetachedChatKind chatKind,
    required String conversationId,
    required Uint8List bytes,
    required String fileName,
    required String type,
    String? replyToId,
    required String messageId,
    bool viewOnce = false,
    required String userId,
    required KeyManager keyManager,
    required List<Contact> contacts,
    required Group? Function(String groupId) groupById,
  }) async {
    switch (chatKind) {
      case DetachedChatKind.direct:
        Contact? contact;
        for (final c in contacts) {
          if (c.id == conversationId) {
            contact = c;
            break;
          }
        }
        final service = ChatService(
          userId: userId,
          peerId: conversationId,
          keyManager: keyManager,
        );
        await service.initialize(contact?.publicKeyPem);
        final id = await service.sendFileMessage(
          bytes,
          fileName,
          type,
          replyToId: replyToId,
          messageId: messageId,
          viewOnce: viewOnce,
        );
        service.dispose();
        if (id != null) {
          await _notifyStatus(
            chatKind: chatKind,
            conversationId: conversationId,
            messageId: messageId,
            status: 'sent',
          );
        }
        return id;
      case DetachedChatKind.self:
        final id = await SelfChatService(userId: userId, keyManager: keyManager)
            .sendFileMessage(
          bytes,
          fileName,
          type,
          replyToId: replyToId,
          messageId: messageId,
          viewOnce: viewOnce,
        );
        await _notifyStatus(
          chatKind: chatKind,
          conversationId: conversationId,
          messageId: messageId,
          status: 'sent',
        );
        return id;
      case DetachedChatKind.group:
        final groupService = GroupService(keyManager: keyManager, userId: userId);
        final chatService = GroupChatService(
          userId: userId,
          groupId: conversationId,
          keyManager: keyManager,
          groupService: groupService,
        );
        await chatService.initialize();
        final id = await chatService.sendFileMessage(
          bytes,
          fileName,
          type,
          replyToId: replyToId,
          messageId: messageId,
          viewOnce: viewOnce,
        );
        chatService.dispose();
        if (id != null) {
          await _notifyStatus(
            chatKind: chatKind,
            conversationId: conversationId,
            messageId: messageId,
            status: 'sent',
          );
        }
        return id;
    }
  }
}
