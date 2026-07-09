import 'package:flutter/widgets.dart';
import 'package:prysm/models/chat/prysm_message.dart';
import 'package:prysm/database/messages.dart';
import 'package:prysm/models/reply_preview_data.dart';
import 'package:prysm/screens/widgets/quoted_reply_preview.dart';
import 'package:prysm/util/reply_preview_label.dart';

class QuotedReplyPreviewLoader extends StatefulWidget {
  final String? replyToMessageId;
  final List<Message> messages;
  final bool isSentByMe;
  final bool compact;
  final String? groupId;
  final String? Function(String authorId)? authorNameFor;
  final void Function(String messageId)? onTap;

  const QuotedReplyPreviewLoader({
    required this.replyToMessageId,
    required this.messages,
    required this.isSentByMe,
    this.compact = false,
    this.groupId,
    this.authorNameFor,
    this.onTap,
    super.key,
  });

  @override
  State<QuotedReplyPreviewLoader> createState() =>
      _QuotedReplyPreviewLoaderState();
}

class _QuotedReplyPreviewLoaderState extends State<QuotedReplyPreviewLoader> {
  ReplyPreviewData? _data;
  String? _loadedForId;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(QuotedReplyPreviewLoader oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.replyToMessageId != widget.replyToMessageId ||
        oldWidget.messages.length != widget.messages.length) {
      _resolve();
    }
  }

  Future<void> _resolve() async {
    final replyId = widget.replyToMessageId;
    if (replyId == null) {
      if (!mounted) return;
      setState(() {
        _data = null;
        _loadedForId = null;
      });
      return;
    }

    Message? inMemory;
    for (final message in widget.messages) {
      if (message.id == replyId) {
        inMemory = message;
        break;
      }
    }

    if (inMemory != null) {
      if (!mounted) return;
      setState(() {
        _data = replyPreviewFromMessage(inMemory!);
        _loadedForId = replyId;
      });
      return;
    }

    if (_loadedForId == replyId && _data != null) return;

    final rows = await MessagesDb.getMessageById(
      replyId,
      groupId: widget.groupId,
    );
    if (!mounted || widget.replyToMessageId != replyId) return;

    setState(() {
      _loadedForId = replyId;
      _data = rows.isEmpty
          ? ReplyPreviewData.unavailable
          : replyPreviewFromDbRow(rows.first);
    });
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    final replyId = widget.replyToMessageId;
    if (replyId == null || data == null) {
      return const SizedBox.shrink();
    }

    final authorName = data.authorId != null && widget.authorNameFor != null
        ? widget.authorNameFor!(data.authorId!)
        : null;

    return QuotedReplyPreview(
      data: data,
      isSentByMe: widget.isSentByMe,
      compact: widget.compact,
      authorName: authorName,
      onTap: widget.onTap == null ? null : () => widget.onTap!(replyId),
    );
  }
}
