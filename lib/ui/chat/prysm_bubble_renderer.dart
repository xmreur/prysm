import 'package:flutter/widgets.dart';
import 'package:prysm/theme/prysm_style_scope.dart';

/// Applies user bubble radius, shadow, and palette colors to message content.
class PrysmBubbleRenderer extends StatelessWidget {
  const PrysmBubbleRenderer({
    required this.isSentByMe,
    required this.child,
    this.padding = const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    this.maxWidth,
    super.key,
  });

  final bool isSentByMe;
  final Widget child;
  final EdgeInsets padding;
  final double? maxWidth;

  @override
  Widget build(BuildContext context) {
    final style = context.prysmStyle;
    final tokens = style.tokens;
    final radius =
        isSentByMe ? style.bubbleSentRadius : style.bubbleReceivedRadius;
    final background = prysmBubbleBackground(context, isSentByMe: isSentByMe);

    Widget bubble = DecoratedBox(
      decoration: BoxDecoration(
        color: background,
        borderRadius: radius,
        boxShadow: style.bubbleShadow,
      ),
      child: Padding(padding: padding, child: child),
    );

    if (maxWidth != null) {
      bubble = ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth!),
        child: bubble,
      );
    }

    return bubble;
  }
}

/// Background fill for sent/received message bubbles.
Color prysmBubbleBackground(BuildContext context, {required bool isSentByMe}) {
  final tokens = context.prysmStyle.tokens;
  return isSentByMe ? tokens.bubbleSent : tokens.bubbleReceived;
}

/// Text color for content inside sent/received bubbles.
Color prysmBubbleTextColor(BuildContext context, {required bool isSentByMe}) {
  final tokens = context.prysmStyle.tokens;
  return isSentByMe ? tokens.onAccent : tokens.textPrimary;
}

Color prysmBubbleMetaColor(BuildContext context, {required bool isSentByMe}) {
  final color = prysmBubbleTextColor(context, isSentByMe: isSentByMe);
  return color.withValues(alpha: 0.65);
}
