import 'package:flutter/widgets.dart';

/// Tap feedback without Material ripple.
class PrysmPressable extends StatefulWidget {
  const PrysmPressable({
    required this.child,
    required this.onTap,
    this.onLongPress,
    this.onLongPressStart,
    this.borderRadius = BorderRadius.zero,
    this.enabled = true,
    super.key,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final GestureLongPressStartCallback? onLongPressStart;
  final BorderRadius borderRadius;
  final bool enabled;

  @override
  State<PrysmPressable> createState() => _PrysmPressableState();
}

class _PrysmPressableState extends State<PrysmPressable> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: widget.enabled ? (_) => setState(() => _pressed = true) : null,
      onTapUp: widget.enabled ? (_) => setState(() => _pressed = false) : null,
      onTapCancel: widget.enabled ? () => setState(() => _pressed = false) : null,
      onTap: widget.enabled ? widget.onTap : null,
      onLongPress: widget.enabled ? widget.onLongPress : null,
      onLongPressStart: widget.enabled ? widget.onLongPressStart : null,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 80),
        opacity: _pressed ? 0.65 : 1,
        child: widget.child,
      ),
    );
  }
}
