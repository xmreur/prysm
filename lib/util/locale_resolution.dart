import 'dart:ui';

import 'package:prysm/l10n/app_localizations.dart';
import 'package:prysm/models/locale_override.dart';

/// Supported app language codes (without region).
const supportedLanguageCodes = {'en', 'it'};

Locale get systemLocale => PlatformDispatcher.instance.locale;

/// Resolves the effective [Locale] from a stored override.
Locale resolveLocale(LocaleOverride override) {
  if (override == LocaleOverride.en) {
    return const Locale('en');
  }
  if (override == LocaleOverride.it) {
    return const Locale('it');
  }
  return resolveLocaleFromLanguageCode(systemLocale.languageCode);
}

Locale resolveLocaleFromLanguageCode(String languageCode) {
  if (supportedLanguageCodes.contains(languageCode)) {
    return Locale(languageCode);
  }
  return const Locale('en');
}

/// Whether [WidgetsApp.locale] should be null (follow OS).
bool usesSystemLocale(LocaleOverride override) =>
    override == LocaleOverride.system;

AppLocalizations lookupAppLocalizationsForOverride(LocaleOverride override) {
  return lookupAppLocalizations(resolveLocale(override));
}
