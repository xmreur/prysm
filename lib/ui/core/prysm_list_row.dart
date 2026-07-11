import 'package:flutter/widgets.dart';
import 'package:prysm/theme/prysm_style_scope.dart';
import 'package:prysm/theme/prysm_tokens.dart';
import 'package:prysm/ui/core/prysm_pressable.dart';

Future<T?> showPrysmSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
}) {
  final tokens = PrysmStyleScope.maybeOf(context)?.tokens;
  final surface = tokens?.surface ?? const Color(0xFF17212B);
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Dismiss',
    barrierColor: const Color(0x66000000),
    transitionDuration: const Duration(milliseconds: 250),
    pageBuilder: (ctx, animation, secondaryAnimation) {
      return Align(
        alignment: Alignment.bottomCenter,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: surface,
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(PrysmTokens.radiusCard),
            ),
          ),
          child: PrysmSheet(child: builder(ctx)),
        ),
      );
    },
    transitionBuilder: (ctx, animation, secondaryAnimation, child) {
      return SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 1),
          end: Offset.zero,
        ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOut)),
        child: child,
      );
    },
  );
}

class PrysmSheet extends StatelessWidget {
  const PrysmSheet({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final style = context.prysmStyle;
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: PrysmTokens.spacing8),
          Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: style.tokens.outline,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: PrysmTokens.spacing8),
          Flexible(child: child),
        ],
      ),
    );
  }
}

class PrysmListRow extends StatelessWidget {
  const PrysmListRow({
    this.onTap,
    this.leading,
    this.title,
    this.titleWidget,
    this.subtitle,
    this.subtitleWidget,
    this.trailing,
    this.trailingSubtitle,
    this.selected = false,
    super.key,
  });

  final VoidCallback? onTap;
  final Widget? leading;
  final String? title;
  final Widget? titleWidget;
  final String? subtitle;
  final Widget? subtitleWidget;
  final Widget? trailing;
  final String? trailingSubtitle;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final style = context.prysmStyle;
    final tokens = style.tokens;

    return PrysmPressable(
      onTap: onTap,
      child: ColoredBox(
        color: selected
            ? Color.lerp(tokens.background, tokens.accent, 0.12)!
            : const Color(0x00000000),
        child: SizedBox(
          height: 72,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: PrysmTokens.spacing12),
            child: Row(
              children: [
                if (leading != null) ...[
                  leading!,
                  const SizedBox(width: PrysmTokens.spacing12),
                ],
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (titleWidget != null)
                        titleWidget!
                      else if (title != null)
                        Text(title!,
                            style: style.titleStyle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                      if (subtitleWidget != null) ...[
                        const SizedBox(height: 2),
                        subtitleWidget!,
                      ] else if (subtitle != null) ...[
                        const SizedBox(height: 2),
                        Text(subtitle!,
                            style: style.captionStyle.copyWith(
                                color: tokens.textSecondary),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                      ],
                    ],
                  ),
                ),
                if (trailingSubtitle != null || trailing != null) ...[
                  const SizedBox(width: PrysmTokens.spacing8),
                  Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      if (trailingSubtitle != null)
                        Text(trailingSubtitle!, style: style.captionStyle),
                      if (trailing != null) ...[
                        if (trailingSubtitle != null)
                          const SizedBox(height: 4),
                        trailing!,
                      ],
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class PrysmUnreadBadge extends StatelessWidget {
  const PrysmUnreadBadge({required this.count, super.key});

  final int count;

  @override
  Widget build(BuildContext context) {
    if (count <= 0) return const SizedBox.shrink();
    final style = context.prysmStyle;
    final label = count > 99 ? '99+' : '$count';
    return DecoratedBox(
      decoration: BoxDecoration(
        color: style.tokens.unreadBadge,
        borderRadius: BorderRadius.circular(PrysmTokens.radiusChip),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Text(
          label,
          style: style.captionStyle.copyWith(
            color: style.tokens.onAccent,
            fontWeight: FontWeight.w600,
            fontSize: 11,
          ),
        ),
      ),
    );
  }
}
