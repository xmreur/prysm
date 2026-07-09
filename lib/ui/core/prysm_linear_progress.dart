import 'package:flutter/widgets.dart';
import 'package:prysm/theme/prysm_style_scope.dart';

class PrysmLinearProgressIndicator extends StatelessWidget {
  const PrysmLinearProgressIndicator({
    this.value,
    this.minHeight = 4,
    super.key,
  });

  final double? value;
  final double minHeight;

  @override
  Widget build(BuildContext context) {
    final tokens = context.prysmStyle.tokens;
    final fraction = value?.clamp(0.0, 1.0);
    return ClipRRect(
      borderRadius: BorderRadius.circular(minHeight / 2),
      child: SizedBox(
        height: minHeight,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(color: tokens.outline.withValues(alpha: 0.35)),
            if (fraction != null)
              FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: fraction,
                child: ColoredBox(color: tokens.accent),
              )
            else
              _IndeterminateBar(color: tokens.accent),
          ],
        ),
      ),
    );
  }
}

class _IndeterminateBar extends StatefulWidget {
  const _IndeterminateBar({required this.color});

  final Color color;

  @override
  State<_IndeterminateBar> createState() => _IndeterminateBarState();
}

class _IndeterminateBarState extends State<_IndeterminateBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth * 0.35;
            final left = (constraints.maxWidth + width) * _controller.value - width;
            return Stack(
              children: [
                Positioned(
                  left: left,
                  width: width,
                  top: 0,
                  bottom: 0,
                  child: ColoredBox(color: widget.color),
                ),
              ],
            );
          },
        );
      },
    );
  }
}
