import 'package:flutter/material.dart';

class DeletedMessageBubble extends StatelessWidget {
  final bool isSentByMe;
  final DateTime createdAt;
  final Widget? tickWidget;

  const DeletedMessageBubble({
    required this.isSentByMe,
    required this.createdAt,
    this.tickWidget,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final timeString =
        '${createdAt.hour.toString().padLeft(2, '0')}:${createdAt.minute.toString().padLeft(2, '0')}';
    final baseColor = isSentByMe
        ? Theme.of(context).colorScheme.primary.withAlpha(120)
        : Theme.of(context).colorScheme.secondary.withAlpha(120);
    final textColor = Theme.of(context).colorScheme.onSurface.withAlpha(140);

    return IntrinsicWidth(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: baseColor,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: Theme.of(context).dividerColor.withAlpha(80),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.block, size: 14, color: textColor),
            const SizedBox(width: 6),
            Text(
              'Deleted',
              style: TextStyle(
                fontSize: 13,
                fontStyle: FontStyle.italic,
                color: textColor,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              timeString,
              style: TextStyle(fontSize: 10, color: textColor.withAlpha(180)),
            ),
            if (tickWidget != null) ...[const SizedBox(width: 4), tickWidget!],
          ],
        ),
      ),
    );
  }
}
