import 'package:flutter/material.dart';
import 'package:flutter_chat_core/flutter_chat_core.dart';

/// Attach reactions map to any supported chat message type.
Message applyReactionsToMessage(
  Message message,
  Map<String, List<String>>? reactions,
) {
  if (reactions == null || reactions.isEmpty) return message;
  return switch (message) {
    TextMessage m => m.copyWith(reactions: reactions),
    ImageMessage m => m.copyWith(reactions: reactions),
    FileMessage m => m.copyWith(reactions: reactions),
    _ => message,
  };
}

/// Compact reaction chips shown below a message bubble.
class MessageReactionBar extends StatelessWidget {
  final Map<String, List<String>> reactions;
  final String currentUserId;
  final bool isSentByMe;
  final ValueChanged<String> onReactionTap;

  const MessageReactionBar({
    required this.reactions,
    required this.currentUserId,
    required this.isSentByMe,
    required this.onReactionTap,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    if (reactions.isEmpty) return const SizedBox.shrink();

    final entries = reactions.entries.toList()
      ..sort((a, b) => b.value.length.compareTo(a.value.length));

    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 2),
      child: Wrap(
        spacing: 4,
        runSpacing: 4,
        alignment: isSentByMe ? WrapAlignment.end : WrapAlignment.start,
        children: [
          for (final entry in entries)
            _ReactionChip(
              emoji: entry.key,
              count: entry.value.length,
              highlighted: entry.value.contains(currentUserId),
              onTap: () => onReactionTap(entry.key),
            ),
        ],
      ),
    );
  }
}

class _ReactionChip extends StatelessWidget {
  final String emoji;
  final int count;
  final bool highlighted;
  final VoidCallback onTap;

  const _ReactionChip({
    required this.emoji,
    required this.count,
    required this.highlighted,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: highlighted
          ? scheme.primaryContainer.withAlpha(200)
          : scheme.surfaceContainerHighest.withAlpha(220),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(emoji, style: const TextStyle(fontSize: 14)),
              if (count > 1) ...[
                const SizedBox(width: 3),
                Text(
                  '$count',
                  style: TextStyle(
                    fontSize: 11,
                    color: scheme.onSurface.withAlpha(180),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
