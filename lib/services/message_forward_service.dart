import 'dart:typed_data';

import 'package:prysm/constants/group_constants.dart';
import 'package:prysm/crypto/wire.dart';
import 'package:prysm/database/messages.dart';
import 'package:prysm/database/self_messages_db.dart';
import 'package:prysm/models/chat/prysm_message.dart';
import 'package:prysm/models/contact.dart';
import 'package:prysm/models/detached_chat_launch.dart';
import 'package:prysm/models/group.dart';
import 'package:prysm/models/share_target.dart';
import 'package:prysm/services/detached_chat_bridge.dart';
import 'package:prysm/services/file_attachment_resolver.dart';
import 'package:prysm/services/group_service.dart';
import 'package:prysm/services/message_view_mapper.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/message_modify_policy.dart';
import 'package:uuid/uuid.dart';

/// Decrypts a message from its DB row and sends a new copy to [target].
class MessageForwardService {
  MessageForwardService._();

  static Future<void> forward({
    required Message message,
    required ShareTarget target,
    required bool markForwarded,
    required DetachedChatKind sourceKind,
    required String sourceConversationId,
    required String userId,
    required KeyManager keyManager,
    required List<Contact> contacts,
    required Group? Function(String groupId) groupById,
  }) async {
    if (!canForwardMessage(message)) {
      throw StateError('Message cannot be forwarded');
    }

    final messageId = const Uuid().v4();

    if (message is TextMessage) {
      final id = await DetachedChatBridge.sendSharedText(
        chatKind: target.kind,
        conversationId: target.conversationId,
        text: message.text,
        messageId: messageId,
        forwarded: markForwarded,
        userId: userId,
        keyManager: keyManager,
        contacts: contacts,
        groupById: groupById,
      );
      if (id == null) {
        throw StateError('Send failed');
      }
      return;
    }

    final row = await _sourceRow(
      messageId: message.id,
      sourceKind: sourceKind,
      sourceConversationId: sourceConversationId,
    );
    final bytes = await _decryptMedia(
      row: row,
      sourceKind: sourceKind,
      sourceConversationId: sourceConversationId,
      userId: userId,
      keyManager: keyManager,
    );
    if (bytes.isEmpty) {
      throw StateError('Could not decrypt media');
    }

    final spec = _mediaSpec(message, row);
    final id = await DetachedChatBridge.sendSharedFile(
      chatKind: target.kind,
      conversationId: target.conversationId,
      bytes: bytes,
      fileName: spec.name,
      type: spec.type,
      messageId: messageId,
      forwarded: markForwarded,
      userId: userId,
      keyManager: keyManager,
      contacts: contacts,
      groupById: groupById,
    );
    if (id == null) {
      throw StateError('Send failed');
    }
  }

  static Future<Map<String, dynamic>> _sourceRow({
    required String messageId,
    required DetachedChatKind sourceKind,
    required String sourceConversationId,
  }) async {
    switch (sourceKind) {
      case DetachedChatKind.direct:
        final rows = await MessagesDb.getMessageById(messageId);
        if (rows.isEmpty) throw StateError('Message not found');
        return rows.first;
      case DetachedChatKind.group:
        final rows = await MessagesDb.getMessageById(
          messageId,
          groupId: sourceConversationId,
        );
        if (rows.isEmpty) throw StateError('Message not found');
        return rows.first;
      case DetachedChatKind.self:
        final rows = await SelfMessagesDb.getMessageById(messageId);
        if (rows.isEmpty) throw StateError('Message not found');
        return rows.first;
    }
  }

  static Future<Uint8List> _decryptMedia({
    required Map<String, dynamic> row,
    required DetachedChatKind sourceKind,
    required String sourceConversationId,
    required String userId,
    required KeyManager keyManager,
  }) async {
    final wire = row['message'] as String? ?? '';
    if (wire.isEmpty) {
      throw StateError('Empty message payload');
    }
    switch (sourceKind) {
      case DetachedChatKind.direct:
        return FileAttachmentResolver.decryptEncryptedSource(
          wire,
          keyManager,
          senderId: row['senderId'] as String?,
          localUserId: userId,
        );
      case DetachedChatKind.group:
        final groupService = GroupService(
          keyManager: keyManager,
          userId: userId,
        );
        return MessageViewMapper(keyManager: keyManager).decryptGroupFileBytes(
          getDecryptedGroupKey: groupService.getDecryptedGroupKey,
          groupId: sourceConversationId,
          row: row,
        );
      case DetachedChatKind.self:
        return CryptoWire.decryptFile(wire, keyManager.identity);
    }
  }

  static ({String name, String type}) _mediaSpec(
    Message message,
    Map<String, dynamic> row,
  ) {
    final dbType = row['type'] as String? ?? '';
    final dbName = row['fileName'] as String?;
    if (message is ImageMessage ||
        dbType == 'image' ||
        dbType == groupImageType) {
      return (name: dbName ?? 'image.jpg', type: 'image');
    }
    if (message is FileMessage &&
        (message.name.contains('voice_message') ||
            dbType == 'audio' ||
            dbType == groupAudioType)) {
      return (name: 'voice_message.wav', type: 'audio');
    }
    return (name: dbName ?? (message as FileMessage).name, type: 'file');
  }
}
