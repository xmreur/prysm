import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:prysm/theme/prysm_style_scope.dart';

/// Material-free loading indicator.
class PrysmProgressIndicator extends StatefulWidget {
  const PrysmProgressIndicator({this.size = 28, super.key});

  final double size;

  @override
  State<PrysmProgressIndicator> createState() => _PrysmProgressIndicatorState();
}

class _PrysmProgressIndicatorState extends State<PrysmProgressIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = context.prysmStyle.tokens.accent;
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          return CustomPaint(
            painter: _ArcPainter(
              color: color,
              progress: _controller.value,
            ),
          );
        },
      ),
    );
  }
}

class _ArcPainter extends CustomPainter {
  _ArcPainter({required this.color, required this.progress});

  final Color color;
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = size.width * 0.1;
    final paint = Paint()
      ..color = color.withValues(alpha: 0.2)
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    final rect = Offset.zero & size;
    canvas.drawArc(rect.deflate(stroke), 0, math.pi * 2, false, paint);

    paint.color = color;
    canvas.drawArc(
      rect.deflate(stroke),
      progress * math.pi * 2,
      math.pi * 0.75,
      false,
      paint,
    );
  }

  @override
  bool shouldRepaint(_ArcPainter oldDelegate) =>
      oldDelegate.progress != progress || oldDelegate.color != color;
}
