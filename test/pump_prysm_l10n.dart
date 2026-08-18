import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/l10n/app_localizations.dart';
import 'package:prysm/models/appearance_settings.dart';
import 'package:prysm/models/locale_override.dart';
import 'package:prysm/theme/prysm_style_resolver.dart';
import 'package:prysm/theme/prysm_style_scope.dart';
import 'package:prysm/util/locale_resolution.dart';

/// Pumps [child] inside Prysm style scope and localization delegates.
Future<void> pumpWithPrysmL10n(
  WidgetTester tester,
  Widget child, {
  LocaleOverride localeOverride = LocaleOverride.en,
  double width = 400,
}) async {
  final locale = resolveLocale(localeOverride);
  await tester.pumpWidget(
    PrysmStyleScope(
      style: PrysmStyleResolver.resolve(
        themePalette: 0,
        appearance: const AppearanceSettings(),
      ),
      child: WidgetsApp(
        locale: locale,
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
        ],
        color: const Color(0xFF000000),
        pageRouteBuilder: <T>(RouteSettings settings, WidgetBuilder builder) =>
            PageRouteBuilder<T>(
          settings: settings,
          pageBuilder: (context, animation, secondaryAnimation) =>
              builder(context),
        ),
        home: Center(child: SizedBox(width: width, child: child)),
      ),
    ),
  );
  await tester.pumpAndSettle();
}
