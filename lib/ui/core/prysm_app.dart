import 'package:flutter/widgets.dart';
import 'package:prysm/models/appearance_settings.dart';
import 'package:prysm/theme/prysm_style_scope.dart';

/// Root app shell — [WidgetsApp] with no Material dependency.
class PrysmApp extends StatelessWidget {
  const PrysmApp({
    required this.themePalette,
    required this.appearance,
    required this.home,
    this.title,
    super.key,
  });

  final int themePalette;
  final AppearanceSettings appearance;
  final Widget home;
  final String? title;

  @override
  Widget build(BuildContext context) {
    return PrysmStyleProvider(
      themePalette: themePalette,
      appearance: appearance,
      child: Builder(
        builder: (context) {
          final style = context.prysmStyle;
          return WidgetsApp(
            title: title ?? 'Prysm',
            color: style.tokens.accent,
            debugShowCheckedModeBanner: false,
            pageRouteBuilder: <T>(
              RouteSettings settings,
              WidgetBuilder builder,
            ) {
              return PageRouteBuilder<T>(
                settings: settings,
                pageBuilder: (context, animation, secondaryAnimation) =>
                    builder(context),
                transitionsBuilder:
                    (context, animation, secondaryAnimation, child) {
                  return FadeTransition(opacity: animation, child: child);
                },
              );
            },
            builder: (context, child) {
              final resolved = PrysmStyleScope.of(context);
              return IconTheme(
                data: IconThemeData(
                  color: resolved.tokens.textSecondary,
                  size: 22,
                ),
                child: DefaultTextStyle(
                  style: resolved.bodyStyle,
                  child: ColoredBox(
                    color: resolved.tokens.background,
                    child: child ?? const SizedBox.shrink(),
                  ),
                ),
              );
            },
            home: home,
          );
        },
      ),
    );
  }
}

/// Fade/slide route without Material.
class PrysmPageRoute<T> extends PageRouteBuilder<T> {
  PrysmPageRoute({required Widget page})
      : super(
          pageBuilder: (context, animation, secondaryAnimation) => page,
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            return FadeTransition(opacity: animation, child: child);
          },
        );
}

Future<T?> prysmPush<T>(BuildContext context, Widget page) {
  return Navigator.of(context).push<T>(PrysmPageRoute<T>(page: page));
}

void prysmPop<T>(BuildContext context, [T? result]) {
  Navigator.of(context).pop(result);
}
