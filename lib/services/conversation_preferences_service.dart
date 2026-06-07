import 'package:prysm/database/conversation_preferences_db.dart';
import 'package:prysm/models/conversation.dart';
import 'package:prysm/models/conversation_preferences.dart';

class ConversationPreferencesService {
  ConversationPreferencesService._();
  static final ConversationPreferencesService instance =
      ConversationPreferencesService._();

  Future<Map<String, ConversationPreferences>> getAll() =>
      ConversationPreferencesDb.getAll();

  Future<void> pin(String conversationId) async {
    final existing = await ConversationPreferencesDb.get(conversationId);
    final now = DateTime.now().millisecondsSinceEpoch;
    await ConversationPreferencesDb.upsert(
      ConversationPreferences(
        conversationId: conversationId,
        isPinned: true,
        pinnedAt: now,
        isArchived: existing?.isArchived ?? false,
        archivedAt: existing?.archivedAt,
      ),
    );
  }

  Future<void> unpin(String conversationId) async {
    final existing = await ConversationPreferencesDb.get(conversationId);
    await ConversationPreferencesDb.upsert(
      ConversationPreferences(
        conversationId: conversationId,
        isPinned: false,
        isArchived: existing?.isArchived ?? false,
        archivedAt: existing?.archivedAt,
      ),
    );
  }

  Future<void> archive(String conversationId) async {
    final existing = await ConversationPreferencesDb.get(conversationId);
    final now = DateTime.now().millisecondsSinceEpoch;
    await ConversationPreferencesDb.upsert(
      ConversationPreferences(
        conversationId: conversationId,
        isPinned: existing?.isPinned ?? false,
        pinnedAt: existing?.pinnedAt,
        isArchived: true,
        archivedAt: now,
      ),
    );
  }

  Future<void> unarchive(String conversationId) async {
    final existing = await ConversationPreferencesDb.get(conversationId);
    if (existing == null || !existing.isArchived) return;
    await ConversationPreferencesDb.upsert(
      ConversationPreferences(
        conversationId: conversationId,
        isPinned: existing.isPinned,
        pinnedAt: existing.pinnedAt,
        isArchived: false,
      ),
    );
  }

  Future<bool> unarchiveIfArchived(String conversationId) async {
    final existing = await ConversationPreferencesDb.get(conversationId);
    if (existing == null || !existing.isArchived) return false;
    await unarchive(conversationId);
    return true;
  }

  Future<void> delete(String conversationId) =>
      ConversationPreferencesDb.delete(conversationId);

  static void sortConversations(
    List<Conversation> conversations,
    Map<String, ConversationPreferences> prefs,
  ) {
    conversations.sort((a, b) {
      final ap = prefs[a.id];
      final bp = prefs[b.id];
      final aPinned = ap?.isPinned ?? false;
      final bPinned = bp?.isPinned ?? false;
      if (aPinned != bPinned) return aPinned ? -1 : 1;
      if (aPinned && bPinned) {
        final aPinAt = ap?.pinnedAt ?? 0;
        final bPinAt = bp?.pinnedAt ?? 0;
        final pinCmp = bPinAt.compareTo(aPinAt);
        if (pinCmp != 0) return pinCmp;
      }
      final aTs = a.lastMessageTimestamp ?? 0;
      final bTs = b.lastMessageTimestamp ?? 0;
      return bTs.compareTo(aTs);
    });
  }
}
