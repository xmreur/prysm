import 'dart:ui';

import 'package:prysm/theme/prysm_tokens.dart';

/// Hand-tuned color palette (no Material seed generation).
class PrysmPalette {
  const PrysmPalette({
    required this.index,
    required this.name,
    required this.tokens,
  });

  final int index;
  final String name;
  final PrysmTokens tokens;

  static const paletteNames = [
    'Light',
    'Dark',
    'Pink',
    'Cyan',
    'Purple',
    'Orange',
  ];

  static PrysmPalette forIndex(int index) {
    switch (index) {
      case 0:
        return light;
      case 1:
        return dark;
      case 2:
        return pink;
      case 3:
        return cyan;
      case 4:
        return purple;
      case 5:
        return orange;
      default:
        return light;
    }
  }

  static const light = PrysmPalette(
    index: 0,
    name: 'Light',
    tokens: PrysmTokens(
      background: Color(0xFFE8EBEF),
      surface: Color(0xFFFFFFFF),
      surfaceElevated: Color(0xFFF4F6F8),
      sidebar: Color(0xFFFFFFFF),
      composer: Color(0xFFFFFFFF),
      bubbleSent: Color(0xFF5B9A8B),
      bubbleReceived: Color(0xFFFFFFFF),
      textPrimary: Color(0xFF1C1C1E),
      textSecondary: Color(0xFF3C3C43),
      textMuted: Color(0xFF8E8E93),
      onAccent: Color(0xFFFFFFFF),
      accent: Color(0xFF3D8B7A),
      accentMuted: Color(0xFF6BA89A),
      divider: Color(0x1A000000),
      outline: Color(0xFFD1D5DB),
      danger: Color(0xFFC0392B),
      unreadBadge: Color(0xFF3D8B7A),
      brightness: Brightness.light,
    ),
  );

  static const dark = PrysmPalette(
    index: 1,
    name: 'Dark',
    tokens: PrysmTokens(
      background: Color(0xFF0E1621),
      surface: Color(0xFF17212B),
      surfaceElevated: Color(0xFF1E2C3A),
      sidebar: Color(0xFF17212B),
      composer: Color(0xFF1E2C3A),
      bubbleSent: Color(0xFF2B5278),
      bubbleReceived: Color(0xFF1E2C3A),
      textPrimary: Color(0xFFF5F5F5),
      textSecondary: Color(0xFFB8C5D0),
      textMuted: Color(0xFF6D7F8F),
      onAccent: Color(0xFFE8F0F8),
      accent: Color(0xFF5B9BD5),
      accentMuted: Color(0xFF4A7FA8),
      divider: Color(0x1AFFFFFF),
      outline: Color(0xFF2A3A4A),
      danger: Color(0xFFE74C3C),
      unreadBadge: Color(0xFF5B9BD5),
      brightness: Brightness.dark,
    ),
  );

  static const pink = PrysmPalette(
    index: 2,
    name: 'Pink',
    tokens: PrysmTokens(
      background: Color(0xFF1A1218),
      surface: Color(0xFF241A22),
      surfaceElevated: Color(0xFF2E222C),
      sidebar: Color(0xFF241A22),
      composer: Color(0xFF2E222C),
      bubbleSent: Color(0xFF7A4A62),
      bubbleReceived: Color(0xFF2E222C),
      textPrimary: Color(0xFFF2E8EE),
      textSecondary: Color(0xFFC9B4C0),
      textMuted: Color(0xFF8A7580),
      onAccent: Color(0xFFFFF5F8),
      accent: Color(0xFFB87A96),
      accentMuted: Color(0xFF9A6278),
      divider: Color(0x1AFFFFFF),
      outline: Color(0xFF3D2E38),
      danger: Color(0xFFE07070),
      unreadBadge: Color(0xFFB87A96),
      brightness: Brightness.dark,
    ),
  );

  static const cyan = PrysmPalette(
    index: 3,
    name: 'Cyan',
    tokens: PrysmTokens(
      background: Color(0xFF0E1519),
      surface: Color(0xFF152025),
      surfaceElevated: Color(0xFF1A2830),
      sidebar: Color(0xFF152025),
      composer: Color(0xFF1A2830),
      bubbleSent: Color(0xFF2A5A66),
      bubbleReceived: Color(0xFF1A2830),
      textPrimary: Color(0xFFE8F0F2),
      textSecondary: Color(0xFFA8BEC4),
      textMuted: Color(0xFF6A858C),
      onAccent: Color(0xFFE8FAFC),
      accent: Color(0xFF5A9AA8),
      accentMuted: Color(0xFF4A808C),
      divider: Color(0x1AFFFFFF),
      outline: Color(0xFF2A3A42),
      danger: Color(0xFFE07070),
      unreadBadge: Color(0xFF5A9AA8),
      brightness: Brightness.dark,
    ),
  );

  static const purple = PrysmPalette(
    index: 4,
    name: 'Purple',
    tokens: PrysmTokens(
      background: Color(0xFF14121E),
      surface: Color(0xFF1C1830),
      surfaceElevated: Color(0xFF241E38),
      sidebar: Color(0xFF1C1830),
      composer: Color(0xFF241E38),
      bubbleSent: Color(0xFF4A3D6E),
      bubbleReceived: Color(0xFF241E38),
      textPrimary: Color(0xFFEDE8F5),
      textSecondary: Color(0xFFB8AED0),
      textMuted: Color(0xFF7A7090),
      onAccent: Color(0xFFF5F0FF),
      accent: Color(0xFF8B7AB8),
      accentMuted: Color(0xFF6E5E98),
      divider: Color(0x1AFFFFFF),
      outline: Color(0xFF342E48),
      danger: Color(0xFFE07070),
      unreadBadge: Color(0xFF8B7AB8),
      brightness: Brightness.dark,
    ),
  );

  static const orange = PrysmPalette(
    index: 5,
    name: 'Orange',
    tokens: PrysmTokens(
      background: Color(0xFF1A1410),
      surface: Color(0xFF2A2018),
      surfaceElevated: Color(0xFF342818),
      sidebar: Color(0xFF2A2018),
      composer: Color(0xFF342818),
      bubbleSent: Color(0xFF6E5230),
      bubbleReceived: Color(0xFF342818),
      textPrimary: Color(0xFFF5EDE4),
      textSecondary: Color(0xFFC9B8A4),
      textMuted: Color(0xFF8A7A68),
      onAccent: Color(0xFFFFF8F0),
      accent: Color(0xFFC49A5A),
      accentMuted: Color(0xFFA88048),
      divider: Color(0x1AFFFFFF),
      outline: Color(0xFF3E3428),
      danger: Color(0xFFE07070),
      unreadBadge: Color(0xFFC49A5A),
      brightness: Brightness.dark,
    ),
  );
}
