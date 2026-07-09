import 'package:prysm/theme/prysm_palette.dart';
import 'package:prysm/theme/prysm_theme.dart';

/// Curated palette presets (no Material [ThemeData]).
class PrysmThemes {
  static const themeNames = PrysmPalette.paletteNames;

  static PrysmThemeData forIndex(int index) {
    return PrysmThemeData.fromPalette(PrysmPalette.forIndex(index));
  }
}
