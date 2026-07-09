import 'package:prysm/theme/prysm_palette.dart';
import 'package:prysm/theme/prysm_theme.dart';

class ThemeManager {
  static PrysmThemeData getPrysmTheme(int themeIndex) {
    final palette = PrysmPalette.forIndex(themeIndex);
    return PrysmThemeData.fromPalette(palette);
  }
}
