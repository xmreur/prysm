import 'dart:ui';

class PrysmTokens {
  const PrysmTokens({
    required this.background,
    required this.surface,
    required this.surfaceElevated,
    required this.sidebar,
    required this.composer,
    required this.bubbleSent,
    required this.bubbleReceived,
    required this.textPrimary,
    required this.textSecondary,
    required this.textMuted,
    required this.onAccent,
    required this.accent,
    required this.accentMuted,
    required this.divider,
    required this.outline,
    required this.danger,
    required this.unreadBadge,
    required this.brightness,
  });

  final Color background;
  final Color surface;
  final Color surfaceElevated;
  final Color sidebar;
  final Color composer;
  final Color bubbleSent;
  final Color bubbleReceived;
  final Color textPrimary;
  final Color textSecondary;
  final Color textMuted;
  final Color onAccent;
  final Color accent;
  final Color accentMuted;
  final Color divider;
  final Color outline;
  final Color danger;
  final Color unreadBadge;
  final Brightness brightness;

  static const spacing4 = 4.0;
  static const spacing8 = 8.0;
  static const spacing12 = 12.0;
  static const spacing16 = 16.0;
  static const spacing20 = 20.0;
  static const spacing24 = 24.0;

  static const radiusChip = 10.0;
  static const radiusBubble = 14.0;
  static const radiusCard = 16.0;
  static const radiusComposer = 20.0;
  static const radiusButton = 8.0;
}
