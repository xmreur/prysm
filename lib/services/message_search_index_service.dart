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
  GroupService? _groupService;
  late final MessageViewMapper _viewMapper =
      MessageViewMapper(keyManager: keyManager);

  GroupService get _groups =>
      _groupService ??= GroupService(userId: userId, keyManager: keyManager);

  /// Searchable direct-message types (mirrors `directMessageTypes`).
  static const List<String> searchableDirectTypes = [
    'text',
    'file',
    'image',
    'audio',
  ];

  /// Searchable group-message types.
  static const List<String> searchableGroupTypes = [
    groupTextType,
    groupImageType,
    groupFileType,
    groupAudioType,
  ];

  /// Runs an index action best-effort: failures are logged and swallowed so
  /// message delivery, notification, and upload flows never depend on FTS.
  static Future<void> indexBestEffort(
    Future<void> Function() action,
  ) async {
    try {
      await action();
    } catch (e, stack) {
      Logging.error(
        'Message search indexing failed: $e\n$stack',
        'MessageSearch',
      );
    }
  }

  static bool isSearchableDirectType(String? type) =>
      type == null || isDirectMessageType(type);

  static bool isSearchableGroupType(String type) => isGroupMessageType(type);

  static bool isSearchableSelfType(String? type) =>
      type == null || searchableDirectTypes.contains(type);

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

  Future<void> removeMessage(
    String messageId, {
    required String conversationId,
    required String scope,
  }) =>
      _dao.remove(messageId, conversationId: conversationId, scope: scope);

  /// Indexes an inbound row; returns false when the row could not be indexed
  /// (decryption failure, missing group text, unreadable payload) so callers
  /// like the backfill can retry it. Legitimate skips (deleted, viewed
  /// view-once, non-searchable type) return true.
  Future<bool> indexInboundRow(
    Map<String, dynamic> row,
    String localUserId,
  ) async {
    if (row['deletedAt'] != null) return true;
    if ((row['viewOnce'] ?? 0) == 1 && (row['viewed'] ?? 0) == 1) return true;

    final storageId = row['id'] as String;
    final wireId = MessageIdCodec.wireIdFromStorage(storageId);
    final type = row['type'] as String?;
    final timestamp = row['timestamp'] as int;
    final groupId = row['groupId'] as String?;
    final senderId = row['senderId'] as String;

    if (groupId != null) {
      if (type == null || !isSearchableGroupType(type)) return true;
      if (type == groupTextType) {
        final text = await _decryptGroupText(row, groupId, senderId);
        if (text == null) return false;
        try {
          await _dao.upsert(
            messageId: wireId,
            conversationId: groupId,
            scope: 'group',
            timestamp: timestamp,
            body: text,
          );
        } catch (e) {
          Logging.error('Search index group-text write failed: $e', 'MessageSearch');
          return false;
        }
      } else {
        final fileName = row['fileName'] as String?;
        if (fileName == null || fileName.trim().isEmpty) return true;
        try {
          await indexOutboundFile(
            messageId: wireId,
            conversationId: groupId,
            scope: 'group',
            timestamp: timestamp,
            fileName: fileName,
          );
        } catch (e) {
          Logging.error('Search index group-file write failed: $e', 'MessageSearch');
          return false;
        }
      }
      return true;
    }

    if (type != null && !isSearchableDirectType(type)) return true;
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
        return true;
      } catch (e) {
        Logging.error('Search index inbound decrypt failed: $e', 'MessageSearch');
        return false;
      }
    } else {
      final fileName = row['fileName'] as String?;
      if (fileName == null || fileName.trim().isEmpty) return true;
      final peerId =
          senderId == localUserId ? row['receiverId'] as String : senderId;
      try {
        await indexOutboundFile(
          messageId: wireId,
          conversationId: peerId,
          scope: 'direct',
          timestamp: timestamp,
          fileName: fileName,
        );
      } catch (e) {
        Logging.error('Search index direct-file write failed: $e', 'MessageSearch');
        return false;
      }
      return true;
    }
  }

  /// Indexes a self-message row; returns false when the row could not be
  /// indexed so callers like the backfill can retry it.
  Future<bool> indexSelfRow(Map<String, dynamic> row) async {
    if (row['deletedAt'] != null) return true;
    if ((row['viewOnce'] ?? 0) == 1 && (row['viewed'] ?? 0) == 1) return true;

    final messageId = row['id'] as String;
    final type = row['type'] as String?;
    final timestamp = row['timestamp'] as int;
    if (!isSearchableSelfType(type)) return true;

    if (type == 'text' || type == null) {
      final wire = row['message'] as String?;
      if (wire == null || wire.isEmpty) return false;
      try {
        final text = await keyManager.decryptMessage(wire);
        await indexSelfText(
          messageId: messageId,
          timestamp: timestamp,
          plaintext: text,
        );
        return true;
      } catch (e) {
        Logging.error('Search index self decrypt failed: $e', 'MessageSearch');
        return false;
      }
    } else {
      final fileName = row['fileName'] as String?;
      if (fileName == null || fileName.trim().isEmpty) return true;
      try {
        await indexSelfFile(
          messageId: messageId,
          timestamp: timestamp,
          fileName: fileName,
        );
      } catch (e) {
        Logging.error('Search index self-file write failed: $e', 'MessageSearch');
        return false;
      }
      return true;
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
      return body.length <= maxLen
          ? body
          : '${_safeSubstring(body, 0, maxLen)}…';
    }

    var matchStart = -1;
    var matchLen = 0;
    for (final token in tokens) {
      final idx = lowerBody.indexOf(token);
      if (idx >= 0 && (matchStart < 0 || idx < matchStart)) {
        matchStart = idx;
        matchLen = token.length;
      }
    }
    if (matchStart < 0) {
      return body.length <= maxLen
          ? body
          : '${_safeSubstring(body, 0, maxLen)}…';
    }

    // matchStart indexes lowerBody; case mapping may change string lengths,
    // so guard it before applying it to body.
    final guardedMatch = matchStart.clamp(0, body.length);
    const pad = 24;
    var start = (guardedMatch - pad).clamp(0, body.length);
    var end = (guardedMatch + matchLen + pad).clamp(0, body.length);
    if (start < body.length && _isLowSurrogate(body.codeUnitAt(start))) {
      start++;
    }
    if (end < body.length && _isSurrogate(body.codeUnitAt(end))) {
      end--;
    }
    if (end < start) end = start;
    var snippet = body.substring(start, end);
    if (start > 0) snippet = '…$snippet';
    if (end < body.length) snippet = '$snippet…';
    if (snippet.length > maxLen) {
      snippet = '${_safeSubstring(snippet, 0, maxLen)}…';
    }
    return snippet;
  }

  static bool _isHighSurrogate(int codeUnit) =>
      codeUnit >= 0xD800 && codeUnit <= 0xDBFF;

  static bool _isLowSurrogate(int codeUnit) =>
      codeUnit >= 0xDC00 && codeUnit <= 0xDFFF;

  static bool _isSurrogate(int codeUnit) =>
      _isHighSurrogate(codeUnit) || _isLowSurrogate(codeUnit);

  /// Substrings [start, end) without splitting a surrogate pair.
  static String _safeSubstring(String value, int start, int end) {
    if (start < value.length && _isLowSurrogate(value.codeUnitAt(start))) {
      start++;
    }
    if (end > start && end < value.length && _isSurrogate(value.codeUnitAt(end))) {
      end--;
    }
    if (end < start) end = start;
    return value.substring(start, end);
  }
}
