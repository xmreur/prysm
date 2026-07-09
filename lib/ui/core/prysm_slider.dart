import 'package:flutter/widgets.dart';
import 'package:prysm/theme/prysm_style_scope.dart';

class PrysmSlider extends StatelessWidget {
  const PrysmSlider({
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.divisions,
    super.key,
  });

  final double value;
  final double min;
  final double max;
  final int? divisions;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final tokens = context.prysmStyle.tokens;
    final fraction = ((value - min) / (max - min)).clamp(0.0, 1.0);

    return LayoutBuilder(
      builder: (context, constraints) {
        final trackWidth = constraints.maxWidth;
        final thumbX = trackWidth * fraction;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragUpdate: (details) {
            final local = details.localPosition.dx.clamp(0.0, trackWidth);
            final next = min + (local / trackWidth) * (max - min);
            if (divisions != null && divisions! > 0) {
              final step = (max - min) / divisions!;
              onChanged((next / step).round() * step);
            } else {
              onChanged(next);
            }
          },
          onTapDown: (details) {
            final local = details.localPosition.dx.clamp(0.0, trackWidth);
            final next = min + (local / trackWidth) * (max - min);
            onChanged(next.clamp(min, max));
          },
          child: SizedBox(
            height: 32,
            child: Stack(
              alignment: Alignment.centerLeft,
              children: [
                Container(
                  height: 4,
                  decoration: BoxDecoration(
                    color: tokens.outline,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Positioned(
                  left: 0,
                  width: thumbX,
                  child: Container(
                    height: 4,
                    decoration: BoxDecoration(
                      color: tokens.accent,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Positioned(
                  left: thumbX - 10,
                  child: Container(
                    width: 20,
                    height: 20,
                    decoration: BoxDecoration(
                      color: tokens.accent,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: tokens.accent.withValues(alpha: 0.35),
                          blurRadius: 4,
                          offset: const Offset(0, 1),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
