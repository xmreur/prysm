import 'package:flutter/widgets.dart';
import 'dart:math' as math;


/// Tap/drag scrubber showing voice message waveform bars.
class VoiceWaveformScrubber extends StatelessWidget {
  final List<double> peaks;
  final double progress;
  final Color activeColor;
  final Color inactiveColor;
  final ValueChanged<double> onSeek;
  final ValueChanged<double>? onScrubUpdate;
  final double height;

  const VoiceWaveformScrubber({
    required this.peaks,
    required this.progress,
    required this.activeColor,
    required this.inactiveColor,
    required this.onSeek,
    this.onScrubUpdate,
    this.height = 20,
    super.key,
  });

  void _handleSeek(BuildContext context, double localX) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || box.size.width <= 0) return;
    final fraction = (localX / box.size.width).clamp(0.0, 1.0);
    onScrubUpdate?.call(fraction);
    onSeek(fraction);
  }

  List<double> get _displayPeaks {
    if (peaks.isEmpty) return List<double>.filled(36, 0.15);
    if (peaks.length <= 36) return peaks;
    final step = peaks.length / 36;
    return List<double>.generate(36, (i) {
      final idx = (i * step).floor().clamp(0, peaks.length - 1);
      return peaks[idx];
    });
  }

  @override
  Widget build(BuildContext context) {
    final displayPeaks = _displayPeaks;

    return LayoutBuilder(
      builder: (context, constraints) {
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) => _handleSeek(context, d.localPosition.dx),
          onHorizontalDragUpdate: (d) {
            final box = context.findRenderObject() as RenderBox?;
            if (box == null || box.size.width <= 0) return;
            final fraction =
                (d.localPosition.dx / box.size.width).clamp(0.0, 1.0);
            onScrubUpdate?.call(fraction);
          },
          onHorizontalDragEnd: (d) {
            final box = context.findRenderObject() as RenderBox?;
            if (box == null || box.size.width <= 0) return;
            final fraction =
                (d.localPosition.dx / box.size.width).clamp(0.0, 1.0);
            onSeek(fraction);
          },
          child: CustomPaint(
            size: Size(constraints.maxWidth, height),
            painter: _WaveformPainter(
              peaks: displayPeaks,
              progress: progress.clamp(0.0, 1.0),
              activeColor: activeColor,
              inactiveColor: inactiveColor,
            ),
          ),
        );
      },
    );
  }
}

class _WaveformPainter extends CustomPainter {
  final List<double> peaks;
  final double progress;
  final Color activeColor;
  final Color inactiveColor;

  _WaveformPainter({
    required this.peaks,
    required this.progress,
    required this.activeColor,
    required this.inactiveColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (peaks.isEmpty || size.width <= 0) return;

    const gap = 1.0;
    final barWidth = math.max(
      1.0,
      (size.width - gap * (peaks.length - 1)) / peaks.length,
    );
    final progressX = size.width * progress;

    for (var i = 0; i < peaks.length; i++) {
      final x = i * (barWidth + gap);
      final barCenter = x + barWidth / 2;
      final amplitude = peaks[i].clamp(0.05, 1.0);
      final barHeight = math.max(2.0, size.height * amplitude);
      final top = (size.height - barHeight) / 2;
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(x, top, barWidth, barHeight),
        const Radius.circular(0.75),
      );
      final paint = Paint()
        ..color = barCenter <= progressX ? activeColor : inactiveColor;
      canvas.drawRRect(rect, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _WaveformPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.peaks != peaks ||
        oldDelegate.activeColor != activeColor ||
        oldDelegate.inactiveColor != inactiveColor;
  }
}
