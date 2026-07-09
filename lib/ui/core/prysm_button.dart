import 'package:flutter/widgets.dart';
import 'package:prysm/theme/prysm_style_scope.dart';
import 'package:prysm/theme/prysm_tokens.dart';
import 'package:prysm/ui/core/prysm_pressable.dart';

enum PrysmButtonVariant { primary, secondary, danger }

class PrysmButton extends StatelessWidget {
  const PrysmButton({
    required this.label,
    required this.onPressed,
    this.variant = PrysmButtonVariant.primary,
    super.key,
  });

  final String label;
  final VoidCallback? onPressed;
  final PrysmButtonVariant variant;

  @override
  Widget build(BuildContext context) {
    final tokens = context.prysmStyle.tokens;
    final (bg, fg) = switch (variant) {
      PrysmButtonVariant.primary => (tokens.accent, tokens.onAccent),
      PrysmButtonVariant.secondary =>
        (tokens.surfaceElevated, tokens.textPrimary),
      PrysmButtonVariant.danger => (tokens.danger, const Color(0xFFFFFFFF)),
    };

    return PrysmPressable(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(PrysmTokens.radiusButton),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: onPressed == null ? Color.lerp(bg, tokens.background, 0.4) : bg,
          borderRadius: BorderRadius.circular(PrysmTokens.radiusButton),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: PrysmTokens.spacing16,
            vertical: PrysmTokens.spacing12,
          ),
          child: Text(
            label,
            style: context.prysmStyle.bodyStyle.copyWith(
              color: fg,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}

class PrysmIconButton extends StatelessWidget {
  const PrysmIconButton({
    required this.icon,
    required this.onPressed,
    this.color,
    this.tooltip,
    this.onLongPressStart,
    super.key,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final String? tooltip;
  final Color? color;
  final GestureLongPressStartCallback? onLongPressStart;

  @override
  Widget build(BuildContext context) {
    final tokens = context.prysmStyle.tokens;
    final iconColor = color ?? tokens.textSecondary;
    final button = PrysmPressable(
      onTap: onPressed,
      onLongPressStart: onLongPressStart,
      borderRadius: BorderRadius.circular(PrysmTokens.radiusButton),
      child: SizedBox(
        width: 48,
        height: 48,
        child: Center(
          child: Icon(
            icon,
            size: 22,
            color: onPressed == null
                ? Color.lerp(iconColor, tokens.background, 0.5)
                : iconColor,
          ),
        ),
      ),
    );
    if (tooltip != null) {
      return Semantics(label: tooltip, button: true, child: button);
    }
    return button;
  }
}
