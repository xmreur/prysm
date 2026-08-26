import 'package:prysm/constants/group_constants.dart';

/// Shared SQL fragments for querying the `messages` table, reused by
/// multiple DAOs (ConversationQueriesDao, ReadReceiptQueriesDao,
/// ConversationListQueriesDao) so the direct-chat conversation/type
/// filtering stays byte-identical across them.
class MessageQueryFilters {
  MessageQueryFilters._();

  static const String directChatTypeFilter =
      "(type IS NULL OR type IN ('text', 'file', 'image', 'audio', 'call', '$disappearingTimerNoticeType'))";

  /// Only rows we can decrypt: our outbound copy or peer deliveries to us.
  /// Also includes local system rows (e.g. call events) from either side.
  static const String directConversationFilter =
      "((senderId = ? AND receiverId = ? AND COALESCE(status, '') != 'received') "
      "OR (senderId = ? AND receiverId = ? AND status = 'received') "
      "OR (senderId = ? AND receiverId = ? AND status = 'system') "
      "OR (senderId = ? AND receiverId = ? AND status = 'system'))";

  /// Columns needed for chat list queries.
  static const List<String> messageListColumns = [
    'id',
    'senderId',
    'receiverId',
    'type',
    'message',
    'fileName',
    'fileSize',
    'timestamp',
    'status',
    'replyTo',
    'viewOnce',
    'viewed',
    'groupId',
    'deletedAt',
    'editedAt',
    'readAt',
    'expiresAt',
    'forwarded',
  ];
}
