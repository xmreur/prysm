import 'package:flutter/widgets.dart';
import 'package:prysm/theme/prysm_palette.dart';
import 'package:prysm/theme/prysm_style_scope.dart';
import 'package:prysm/theme/prysm_tokens.dart';

/// Legacy palette accessor — prefer [PrysmStyleScope] / [context.prysmStyle].
class PrysmThemeData {
  const PrysmThemeData({
    required this.tokens,
    required this.index,
    required this.name,
  });

  final PrysmTokens tokens;
  final int index;
  final String name;

  factory PrysmThemeData.fromPalette(PrysmPalette palette) => PrysmThemeData(
        tokens: palette.tokens,
        index: palette.index,
        name: palette.name,
      );
}

class PrysmTheme extends InheritedWidget {
  const PrysmTheme({
    required this.data,
    required super.child,
    super.key,
  });

  final PrysmThemeData data;

  static PrysmThemeData of(BuildContext context) {
    final style = PrysmStyleScope.maybeOf(context);
    if (style != null) {
      return PrysmThemeData(
        tokens: style.tokens,
        index: style.palette.index,
        name: style.palette.name,
      );
    }
    final widget = context.dependOnInheritedWidgetOfExactType<PrysmTheme>();
    assert(widget != null, 'PrysmTheme not found in context');
    return widget!.data;
  }

  static PrysmTokens tokensOf(BuildContext context) => of(context).tokens;

  @override
  bool updateShouldNotify(PrysmTheme oldWidget) => data != oldWidget.data;
}

extension PrysmThemeContext on BuildContext {
  PrysmThemeData get prysmTheme => PrysmTheme.of(this);
  PrysmTokens get prysmTokens => PrysmTheme.tokensOf(this);
}
