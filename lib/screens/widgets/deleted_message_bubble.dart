import 'package:flutter/widgets.dart';
import 'package:prysm/ui/core/prysm_icons.dart';
import 'package:prysm/theme/prysm_style_scope.dart';

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
        ? context.prysmStyle.tokens.accent.withAlpha(120)
        : context.prysmStyle.tokens.accentMuted.withAlpha(120);
    final textColor = context.prysmStyle.tokens.textPrimary.withAlpha(140);

    return IntrinsicWidth(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: baseColor,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: context.prysmStyle.tokens.divider.withAlpha(80),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(PrysmIcons.block, size: 14, color: textColor),
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
