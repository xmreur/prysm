import 'package:prysm/database/pinned_messages_db.dart';

/// Local-only per-conversation message pins.
class PinnedMessagesService {
  PinnedMessagesService._();

  static Future<void> pin({
    required String messageId,
    required String conversationId,
    required String scope,
  }) {
    return PinnedMessagesDb.pin(
      messageId: messageId,
      conversationId: conversationId,
      scope: scope,
    );
  }

  static Future<void> unpin({
    required String messageId,
    required String conversationId,
    required String scope,
  }) {
    return PinnedMessagesDb.unpin(
      messageId: messageId,
      conversationId: conversationId,
      scope: scope,
    );
  }

  static Future<bool> isPinned({
    required String messageId,
    required String conversationId,
    required String scope,
  }) {
    return PinnedMessagesDb.isPinned(
      messageId: messageId,
      conversationId: conversationId,
      scope: scope,
    );
  }

  static Future<Set<String>> pinnedIdsForConversation({
    required String conversationId,
    required String scope,
  }) {
    return PinnedMessagesDb.pinnedIds(
      conversationId: conversationId,
      scope: scope,
    );
  }

  static Future<List<PinnedMessageRow>> listPinned({
    required String conversationId,
    required String scope,
  }) {
    return PinnedMessagesDb.listPinned(
      conversationId: conversationId,
      scope: scope,
    );
  }
}
