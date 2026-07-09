import 'package:flutter/widgets.dart';
import 'package:prysm/theme/prysm_style_scope.dart';
import 'package:prysm/ui/core/prysm_pressable.dart';

class PrysmDivider extends StatelessWidget {
  const PrysmDivider({this.height = 1, this.indent = 0, super.key});

  final double height;
  final double indent;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      margin: EdgeInsets.only(left: indent),
      color: context.prysmStyle.tokens.divider,
    );
  }
}

class PrysmTextButton extends StatelessWidget {
  const PrysmTextButton({
    required this.label,
    required this.onPressed,
    this.color,
    super.key,
  });

  final String label;
  final VoidCallback? onPressed;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final style = context.prysmStyle;
    final fg = color ?? style.tokens.accent;
    return PrysmPressable(
      onTap: onPressed,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Text(
          label,
          style: style.bodyStyle.copyWith(
            color: onPressed == null
                ? Color.lerp(fg, style.tokens.background, 0.5)
                : fg,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class PrysmLinkButton extends StatelessWidget {
  const PrysmLinkButton({
    required this.child,
    required this.onPressed,
    this.color,
    super.key,
  });

  final Widget child;
  final VoidCallback? onPressed;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final style = context.prysmStyle;
    final fg = color ?? style.tokens.accent;
    return PrysmPressable(
      onTap: onPressed,
      child: DefaultTextStyle(
        style: style.bodyStyle.copyWith(
          color: onPressed == null
              ? Color.lerp(fg, style.tokens.background, 0.5)
              : fg,
          fontWeight: FontWeight.w600,
        ),
        child: child,
      ),
    );
  }
}
