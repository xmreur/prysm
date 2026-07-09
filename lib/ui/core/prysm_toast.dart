import 'package:flutter/widgets.dart';
import 'package:prysm/theme/prysm_style_scope.dart';

void showPrysmToast(BuildContext context, String message) {
  final overlay = Overlay.of(context);
  late OverlayEntry entry;
  entry = OverlayEntry(
    builder: (ctx) {
      final style = PrysmStyleScope.maybeOf(ctx);
      final tokens = style?.tokens;
      return Positioned(
        left: 16,
        right: 16,
        bottom: MediaQuery.paddingOf(ctx).bottom + 24,
        child: IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: tokens?.surfaceElevated ?? const Color(0xFF1E2C3A),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Text(
                message,
                textAlign: TextAlign.center,
                style: style?.bodyStyle ??
                    const TextStyle(color: Color(0xFFF5F5F5)),
              ),
            ),
          ),
        ),
      );
    },
  );
  overlay.insert(entry);
  Future.delayed(const Duration(seconds: 3), () {
    entry.remove();
  });
}
