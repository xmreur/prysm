import 'package:prysm/models/conversation_draft.dart';
import 'package:prysm/models/reply_preview_data.dart';

/// In-memory per-conversation drafts (lost when the app process exits).
class MessageDraftStore {
  MessageDraftStore._();

  static final MessageDraftStore instance = MessageDraftStore._();

  final Map<String, ConversationDraft> _drafts = {};

  ConversationDraft get(String key) => _drafts[key] ?? const ConversationDraft();

  void setText(String key, String text) {
    final existing = get(key);
    final updated = existing.copyWith(text: text);
    _upsertOrRemove(key, updated);
  }

  void setReply(String key, ReplyPreviewData? reply) {
    final existing = get(key);
    final updated = reply == null
        ? existing.copyWith(clearReply: true)
        : existing.copyWith(reply: reply);
    _upsertOrRemove(key, updated);
  }

  void clear(String key) {
    _drafts.remove(key);
  }

  void clearAll() {
    _drafts.clear();
  }

  void _upsertOrRemove(String key, ConversationDraft draft) {
    if (draft.isEmpty) {
      _drafts.remove(key);
      return;
    }
    _drafts[key] = draft;
  }
}
