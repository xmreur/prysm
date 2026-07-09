import 'package:flutter/widgets.dart';
import 'package:prysm/ui/core/prysm_icons.dart';
import 'package:prysm/ui/core/prysm_tabs.dart';

/// Overlays a small jump-to-bottom FAB above [child] (e.g. chat list).
class JumpToBottomFabOverlay extends StatelessWidget {
  const JumpToBottomFabOverlay({
    required this.visible,
    required this.onPressed,
    required this.child,
    this.bottom = 80,
    super.key,
  });

  final bool visible;
  final VoidCallback onPressed;
  final Widget child;
  final double bottom;

  static const _duration = Duration(milliseconds: 200);

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        child,
        Positioned(
          right: 16,
          bottom: bottom,
          child: IgnorePointer(
            ignoring: !visible,
            child: AnimatedOpacity(
              opacity: visible ? 1 : 0,
              duration: _duration,
              child: AnimatedScale(
                scale: visible ? 1 : 0.8,
                duration: _duration,
                child: PrysmFab(
                  icon: PrysmIcons.keyboardArrowDown,
                  onPressed: onPressed,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
