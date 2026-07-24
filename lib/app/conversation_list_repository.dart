import 'package:prysm/database/messages.dart';
import 'package:prysm/database/self_messages_db.dart';
import 'package:prysm/models/conversation_preferences.dart';
import 'package:prysm/services/conversation_preferences_service.dart';
import 'package:prysm/util/db_helper.dart';

/// Data access for the conversation list (Fase 5B extraction of the direct
/// DB/service calls that lived inline in `_HomeScreenState.loadUsers`).
///
/// Each method is a thin 1:1 delegation to the existing static DB/service
/// APIs — no new query, no new merge/sort logic. `_HomeScreenState` keeps
/// composing these futures exactly as before (same `Future.wait` groupings,
/// same light/fast/deferred branching); only the call targets moved here so
/// they can be exercised against an in-memory sqflite db independently of
/// the widget.
class ConversationListRepository {
  const ConversationListRepository();

  /// All known users/contacts (`users` table).
  Future<List<Map<String, dynamic>>> getUsers() => DBHelper.getUsers();

  /// Latest message timestamp per peer/group id, across all conversations.
  Future<Map<String, int>> getLastMessageTimestampsForAllUsers() =>
      MessagesDb.getLastMessageTimestampsForAllUsers();

  /// Latest message preview label per conversation id, for [userId].
  Future<Map<String, String>> getLastMessagePreviews(String userId) =>
      MessagesDb.getLastMessagePreviews(userId);

  /// Unread message counts per conversation id, for [userId].
  Future<Map<String, int>> getUnreadCounts(String userId) =>
      MessagesDb.getUnreadCounts(userId);

  /// Pin/archive preferences for every conversation.
  Future<Map<String, ConversationPreferences>> getConversationPreferences() =>
      ConversationPreferencesService.instance.getAll();

  /// Timestamp of the latest self-chat (notes-to-self) message, if any.
  Future<int?> getSelfChatLastTimestamp() => SelfMessagesDb.getLastTimestamp();

  /// Preview label of the latest self-chat message, if any.
  Future<String?> getSelfChatLastPreview() => SelfMessagesDb.getLastPreview();
}
