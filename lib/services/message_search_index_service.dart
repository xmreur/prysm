import 'package:prysm/constants/group_constants.dart';
import 'package:prysm/crypto/group_crypto.dart';
import 'package:prysm/database/message_id_codec.dart';
import 'package:prysm/database/message_search_dao.dart';
import 'package:prysm/models/conversation.dart';
import 'package:prysm/services/group_service.dart';
import 'package:prysm/services/message_view_mapper.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/logging.dart';
import 'package:prysm/util/peer_identity_loader.dart';

/// Keeps the FTS5 search index in sync with message lifecycle events.
class MessageSearchIndexService {
  MessageSearchIndexService({
    MessageSearchDao? dao,
    required this.keyManager,
    required this.userId,
    GroupService? groupService,
  })  : _dao = dao ?? const MessageSearchDao(),
        _groupService = groupService;

  final MessageSearchDao _dao;
  final KeyManager keyManager;
  final String userId;
  final GroupService? _groupService;
  late final MessageViewMapper _viewMapper =
      MessageViewMapper(keyManager: keyManager);

  GroupService get _groups =>
      _groupService ?? GroupService(userId: userId, keyManager: keyManager);

  static bool isSearchableDirectType(String? type) =>
      type == null || isDirectMessageType(type);

  static bool isSearchableGroupType(String type) => isGroupMessageType(type);

  static bool isSearchableSelfType(String? type) =>
      type == null || type == 'text' || type == 'file' || type == 'image' || type == 'audio';

  Future<void> indexOutboundDirectText({
    required String messageId,
    required String peerId,
    required int timestamp,
    required String plaintext,
  }) =>
      _dao.upsert(
        messageId: messageId,
        conversationId: peerId,
        scope: 'direct',
        timestamp: timestamp,
        body: plaintext,
      );

  Future<void> indexOutboundGroupText({
    required String messageId,
    required String groupId,
    required int timestamp,
    required String plaintext,
  }) =>
      _dao.upsert(
        messageId: messageId,
        conversationId: groupId,
        scope: 'group',
        timestamp: timestamp,
        body: plaintext,
      );

  Future<void> indexOutboundFile({
    required String messageId,
    required String conversationId,
    required String scope,
    required int timestamp,
    required String fileName,
  }) =>
      _dao.upsert(
        messageId: messageId,
        conversationId: conversationId,
        scope: scope,
        timestamp: timestamp,
        body: fileName,
      );

  Future<void> indexSelfText({
    required String messageId,
    required int timestamp,
    required String plaintext,
  }) =>
      _dao.upsert(
        messageId: messageId,
        conversationId: SelfConversation.conversationId,
        scope: 'self',
        timestamp: timestamp,
        body: plaintext,
      );

  Future<void> indexSelfFile({
    required String messageId,
    required int timestamp,
    required String fileName,
  }) =>
      indexOutboundFile(
        messageId: messageId,
        conversationId: SelfConversation.conversationId,
        scope: 'self',
        timestamp: timestamp,
        fileName: fileName,
      );

  Future<void> reindexEditedMessage({
    required String messageId,
    required String conversationId,
    required String scope,
    required int timestamp,
    required String plaintext,
  }) =>
      _dao.upsert(
        messageId: messageId,
        conversationId: conversationId,
        scope: scope,
        timestamp: timestamp,
        body: plaintext,
      );

  Future<void> removeMessage(String messageId) => _dao.remove(messageId);

  Future<void> indexInboundRow(
    Map<String, dynamic> row,
    String localUserId,
  ) async {
    if (row['deletedAt'] != null) return;
    if ((row['viewOnce'] ?? 0) == 1 && (row['viewed'] ?? 0) == 1) return;

    final storageId = row['id'] as String;
    final wireId = MessageIdCodec.wireIdFromStorage(storageId);
    final type = row['type'] as String?;
    final timestamp = row['timestamp'] as int;
    final groupId = row['groupId'] as String?;
    final senderId = row['senderId'] as String;

    if (groupId != null) {
      if (type == null || !isSearchableGroupType(type)) return;
      if (type == groupTextType) {
        final text = await _decryptGroupText(row, groupId, senderId);
        if (text == null) return;
        await _dao.upsert(
          messageId: wireId,
          conversationId: groupId,
          scope: 'group',
          timestamp: timestamp,
          body: text,
        );
      } else {
        final fileName = row['fileName'] as String?;
        if (fileName == null || fileName.trim().isEmpty) return;
        await indexOutboundFile(
          messageId: wireId,
          conversationId: groupId,
          scope: 'group',
          timestamp: timestamp,
          fileName: fileName,
        );
      }
      return;
    }

    if (type != null && !isSearchableDirectType(type)) return;
    if (type == 'text' || type == null) {
      try {
        final text = await _viewMapper.decryptDirectTextMessage(
          row,
          localUserId: localUserId,
        );
        final peerId = senderId == localUserId
            ? row['receiverId'] as String
            : senderId;
        await _dao.upsert(
          messageId: wireId,
          conversationId: peerId,
          scope: 'direct',
          timestamp: timestamp,
          body: text,
        );
      } catch (e) {
        Logging.error('Search index inbound decrypt failed: $e', 'MessageSearch');
      }
    } else {
      final fileName = row['fileName'] as String?;
      if (fileName == null || fileName.trim().isEmpty) return;
      final peerId =
          senderId == localUserId ? row['receiverId'] as String : senderId;
      await indexOutboundFile(
        messageId: wireId,
        conversationId: peerId,
        scope: 'direct',
        timestamp: timestamp,
        fileName: fileName,
      );
    }
  }

  Future<void> indexSelfRow(Map<String, dynamic> row) async {
    if (row['deletedAt'] != null) return;
    if ((row['viewOnce'] ?? 0) == 1 && (row['viewed'] ?? 0) == 1) return;

    final messageId = row['id'] as String;
    final type = row['type'] as String?;
    final timestamp = row['timestamp'] as int;
    if (!isSearchableSelfType(type)) return;

    if (type == 'text' || type == null) {
      final wire = row['message'] as String?;
      if (wire == null || wire.isEmpty) return;
      try {
        final text = await keyManager.decryptMessage(wire);
        await indexSelfText(
          messageId: messageId,
          timestamp: timestamp,
          plaintext: text,
        );
      } catch (e) {
        Logging.error('Search index self decrypt failed: $e', 'MessageSearch');
      }
    } else {
      final fileName = row['fileName'] as String?;
      if (fileName == null || fileName.trim().isEmpty) return;
      await indexSelfFile(
        messageId: messageId,
        timestamp: timestamp,
        fileName: fileName,
      );
    }
  }

  Future<String?> _decryptGroupText(
    Map<String, dynamic> row,
    String groupId,
    String senderId,
  ) async {
    final groupKey = await _groups.getDecryptedGroupKey(groupId);
    if (groupKey == null) return null;
    final wire = row['message'] as String?;
    if (wire == null || wire.isEmpty) return null;
    try {
      if (GroupCryptoV2.isSenderKeyEnvelope(wire)) {
        final senderKeys = await loadPeerIdentityFromDb(keyManager, senderId);
        if (senderKeys == null) return null;
        return GroupCryptoV2.decryptWithSenderKey(
          epochKey: groupKey,
          groupId: groupId,
          wire: wire,
          transportSenderId: senderId,
          senderKeys: senderKeys,
        );
      }
      return GroupCryptoV2.decryptText(groupKey, wire);
    } catch (e) {
      Logging.error('Search index group decrypt failed: $e', 'MessageSearch');
      return null;
    }
  }

  static String buildSnippet(String body, String query, {int maxLen = 80}) {
    final lowerBody = body.toLowerCase();
    final tokens = query
        .trim()
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty)
        .toList();
    if (tokens.isEmpty) {
      return body.length <= maxLen ? body : '${body.substring(0, maxLen)}…';
    }

    var matchStart = -1;
    var matchLen = 0;
    for (final token in tokens) {
      final idx = lowerBody.indexOf(token);
      if (idx >= 0) {
        matchStart = idx;
        matchLen = token.length;
        break;
      }
    }
    if (matchStart < 0) {
      return body.length <= maxLen ? body : '${body.substring(0, maxLen)}…';
    }

    const pad = 24;
    final start = (matchStart - pad).clamp(0, body.length);
    final end = (matchStart + matchLen + pad).clamp(0, body.length);
    var snippet = body.substring(start, end);
    if (start > 0) snippet = '…$snippet';
    if (end < body.length) snippet = '$snippet…';
    if (snippet.length > maxLen) {
      snippet = '${snippet.substring(0, maxLen)}…';
    }
    return snippet;
  }
}
