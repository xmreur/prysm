import 'package:flutter/widgets.dart';
import 'package:prysm/models/chat/prysm_message.dart';
import 'package:prysm/theme/prysm_style_scope.dart';
import 'package:prysm/ui/chat/prysm_date_header.dart';

/// Unified message row: date header, swipe-to-reply, selection, highlight.
class PrysmMessageRow extends StatelessWidget {
  const PrysmMessageRow({
    required this.message,
    required this.index,
    required this.messages,
    required this.localUserId,
    required this.displayChild,
    required this.reactionBar,
    required this.swipeDragOffset,
    required this.swipeDragMessageId,
    required this.onSwipeMessageIdChanged,
    required this.isSelected,
    required this.isHighlighted,
    required this.selectionActive,
    this.onToggleSelect,
    this.onReply,
    this.onLongPressMenu,
    super.key,
  });

  final Message message;
  final int index;
  final List<Message> messages;
  final String localUserId;
  final Widget displayChild;
  final Widget reactionBar;
  final ValueNotifier<double> swipeDragOffset;
  final String? swipeDragMessageId;
  final ValueChanged<String?> onSwipeMessageIdChanged;
  final bool isSelected;
  final bool isHighlighted;
  final bool selectionActive;
  final VoidCallback? onToggleSelect;
  final VoidCallback? onReply;
  final void Function(Offset globalPosition)? onLongPressMenu;

  @override
  Widget build(BuildContext context) {
    final isSentByMe = message.authorId == localUserId;
    final msgDate = message.createdAt ?? DateTime.now();
    final showDateHeader = shouldShowChatDateHeader(messages, index);
    final style = context.prysmStyle;
    final tokens = style.tokens;

    return Column(
      children: [
        if (showDateHeader) PrysmDateHeader(date: msgDate),
        GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: selectionActive ? onToggleSelect : null,
          onHorizontalDragUpdate: (details) {
            onSwipeMessageIdChanged(message.id);
            var delta = details.delta.dx;
            if (isSentByMe) delta = -delta;
            var next = swipeDragOffset.value + delta;
            if (next < 0) next = 0;
            if (next > 100) next = 100;
            swipeDragOffset.value = next;
          },
          onHorizontalDragEnd: (_) {
            final shouldReply =
                swipeDragMessageId == message.id && swipeDragOffset.value > 50;
            swipeDragOffset.value = 0;
            onSwipeMessageIdChanged(null);
            if (shouldReply) onReply?.call();
          },
          onLongPressStart: (details) {
            if (selectionActive) {
              onToggleSelect?.call();
            } else {
              onLongPressMenu?.call(details.globalPosition);
            }
          },
          child: ValueListenableBuilder<double>(
            valueListenable: swipeDragOffset,
            builder: (context, dragValue, translatedChild) {
              final offset =
                  swipeDragMessageId == message.id ? dragValue : 0.0;
              return Transform.translate(
                offset: Offset(isSentByMe ? -offset : offset, 0),
                child: translatedChild,
              );
            },
            child: ColoredBox(
              color: isSelected
                  ? Color.lerp(tokens.background, tokens.accent, 0.15)!
                  : isHighlighted
                      ? Color.lerp(tokens.background, tokens.accentMuted, 0.25)!
                      : const Color(0x00000000),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                child: Row(
                  mainAxisAlignment: isSentByMe
                      ? MainAxisAlignment.end
                      : MainAxisAlignment.start,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Flexible(
                      child: Column(
                        crossAxisAlignment: isSentByMe
                            ? CrossAxisAlignment.end
                            : CrossAxisAlignment.start,
                        children: [
                          displayChild,
                          reactionBar,
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
