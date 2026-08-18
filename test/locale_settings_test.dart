import 'dart:convert';

import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/l10n/app_localizations.dart';
import 'package:prysm/models/locale_override.dart';
import 'package:prysm/models/settings.dart';
import 'package:prysm/services/settings_service.dart';
import 'package:prysm/util/locale_resolution.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('localeOverride defaults to system', () {
    final settings = Settings();
    expect(settings.localeOverride, LocaleOverride.system);
  });

  test('localeOverride round-trips through JSON', () {
    final original = Settings(localeOverride: LocaleOverride.it);
    final restored = Settings.fromJson(original.toJson());
    expect(restored.localeOverride, LocaleOverride.it);
  });

  test('unknown localeOverride falls back to system', () {
    final restored = Settings.fromJson({
      'localeOverride': 'fr',
    });
    expect(restored.localeOverride, LocaleOverride.system);
  });

  test('setLocaleOverride persists and bumps revision', () async {
    final service = SettingsService();
    await service.init();
    final before = service.localeRevision.value;
    await service.setLocaleOverride(LocaleOverride.it);
    expect(service.localeOverride, LocaleOverride.it);
    expect(service.localeRevision.value, greaterThan(before));

    final prefs = await SharedPreferences.getInstance();
    final stored = Settings.fromJson(
      jsonDecode(prefs.getString('app_settings')!) as Map<String, dynamic>,
    );
    expect(stored.localeOverride, LocaleOverride.it);
  });

  test('resolveLocale uses override when set', () async {
    final service = SettingsService();
    await service.init();
    await service.setLocaleOverride(LocaleOverride.it);
    expect(service.resolvedLocale, const Locale('it'));
  });

  test('resolveLocale falls back to en for unsupported OS language', () {
    expect(
      resolveLocaleFromLanguageCode('de'),
      const Locale('en'),
    );
  });

  test('lookupAppLocalizations works without widget tree', () {
    final en = lookupAppLocalizations(const Locale('en'));
    final it = lookupAppLocalizations(const Locale('it'));
    expect(en.settingsTitle, 'Settings');
    expect(it.settingsTitle, isNot('Settings'));
  });

  test('init survives corrupt app_settings JSON', () async {
    SharedPreferences.setMockInitialValues({
      'app_settings': '{not valid json',
    });
    final service = SettingsService();
    await expectLater(service.init(), completes);
    expect(service.themeMode, isA<int>());
    expect(service.localeOverride, LocaleOverride.system);
  });

  test('imported settings preserve localeOverride', () async {
    final service = SettingsService();
    await service.init();
    final json = jsonEncode(
      Settings(localeOverride: LocaleOverride.en).toJson(),
    );
    expect(await service.importSettings(json), isTrue);
    expect(service.localeOverride, LocaleOverride.en);
  });
}
