import 'dart:ui';

import 'package:flutter/painting.dart';
import 'package:prysm/models/appearance_settings.dart';
import 'package:prysm/theme/prysm_palette.dart';
import 'package:prysm/theme/prysm_tokens.dart';

/// Fully resolved visual style: palette colors + user appearance prefs.
class PrysmResolvedStyle {
  const PrysmResolvedStyle({
    required this.palette,
    required this.appearance,
    required this.tokens,
    required this.titleStyle,
    required this.headlineStyle,
    required this.bodyStyle,
    required this.captionStyle,
    required this.monoStyle,
    required this.bubbleSentRadius,
    required this.bubbleReceivedRadius,
    required this.composerRadius,
    required this.bubbleShadow,
  });

  final PrysmPalette palette;
  final AppearanceSettings appearance;
  final PrysmTokens tokens;

  final TextStyle titleStyle;
  final TextStyle headlineStyle;
  final TextStyle bodyStyle;
  final TextStyle captionStyle;
  final TextStyle monoStyle;

  final BorderRadius bubbleSentRadius;
  final BorderRadius bubbleReceivedRadius;
  final BorderRadius composerRadius;
  final List<BoxShadow> bubbleShadow;

  bool get isLight => tokens.brightness == Brightness.light;

  TextStyle get title => titleStyle;
  TextStyle get headline => headlineStyle;
  TextStyle get body => bodyStyle;
  TextStyle get caption => captionStyle;
  TextStyle get mono => monoStyle;
}

class PrysmStyleResolver {
  static PrysmResolvedStyle resolve({
    required int themePalette,
    required AppearanceSettings appearance,
  }) {
    final palette = PrysmPalette.forIndex(themePalette);
    final prefs = appearance.clamped();
    final tokens = palette.tokens;
    final scale = prefs.textScale;
    final mainFamily = prefs.fontFamily.family;
    final monoFamily = PrysmFontFamily.jetBrainsMono.family ?? 'monospace';

    TextStyle base({
      required double size,
      required FontWeight weight,
      required Color color,
      String? family,
      double? height,
    }) {
      return TextStyle(
        fontSize: size * scale,
        fontWeight: weight,
        color: color,
        fontFamily: family,
        height: height,
      );
    }

    final r = prefs.messageBubbleRadius;
    const small = 4.0;

    List<BoxShadow> shadow = const [];
    if (prefs.messageShadows) {
      final alpha = (prefs.messageShadowStrength * 255).round().clamp(0, 80);
      shadow = [
        BoxShadow(
          color: Color.fromARGB(
            alpha,
            tokens.brightness == Brightness.light ? 0 : 0,
            tokens.brightness == Brightness.light ? 0 : 0,
            tokens.brightness == Brightness.light ? 0 : 0,
          ),
          blurRadius: 8,
          offset: const Offset(0, 2),
        ),
      ];
    }

    return PrysmResolvedStyle(
      palette: palette,
      appearance: prefs,
      tokens: tokens,
      titleStyle: base(
        size: 16,
        weight: FontWeight.w600,
        color: tokens.textPrimary,
        family: mainFamily,
        height: 1.25,
      ),
      headlineStyle: base(
        size: 20,
        weight: FontWeight.w600,
        color: tokens.textPrimary,
        family: mainFamily,
        height: 1.3,
      ),
      bodyStyle: base(
        size: 15,
        weight: FontWeight.w400,
        color: tokens.textPrimary,
        family: mainFamily,
        height: 1.35,
      ),
      captionStyle: base(
        size: 12,
        weight: FontWeight.w400,
        color: tokens.textMuted,
        family: mainFamily,
        height: 1.3,
      ),
      monoStyle: base(
        size: 13,
        weight: FontWeight.w500,
        color: tokens.textSecondary,
        family: prefs.fontFamily == PrysmFontFamily.jetBrainsMono
            ? monoFamily
            : monoFamily,
        height: 1.3,
      ),
      bubbleSentRadius: BorderRadius.only(
        topLeft: Radius.circular(r),
        topRight: Radius.circular(r),
        bottomLeft: Radius.circular(r),
        bottomRight: const Radius.circular(small),
      ),
      bubbleReceivedRadius: BorderRadius.only(
        topLeft: Radius.circular(r),
        topRight: Radius.circular(r),
        bottomLeft: const Radius.circular(small),
        bottomRight: Radius.circular(r),
      ),
      composerRadius: BorderRadius.circular(prefs.composerRadius),
      bubbleShadow: shadow,
    );
  }
}
