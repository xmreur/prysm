import 'package:prysm/models/reply_preview_data.dart';

class ConversationDraft {
  const ConversationDraft({
    this.text = '',
    this.reply,
  });

  final String text;
  final ReplyPreviewData? reply;

  bool get isEmpty => text.isEmpty && reply == null;

  ConversationDraft copyWith({
    String? text,
    ReplyPreviewData? reply,
    bool clearReply = false,
  }) {
    return ConversationDraft(
      text: text ?? this.text,
      reply: clearReply ? null : (reply ?? this.reply),
    );
  }
}
