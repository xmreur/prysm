import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/l10n/app_localizations.dart';
import 'package:prysm/l10n/l10n_enum_extensions.dart';
import 'package:prysm/models/group_invite_mode.dart';
import 'package:prysm/screens/privacy_settings_screen.dart';
import 'package:prysm/services/settings_service.dart';
import 'package:prysm/ui/core/prysm_switch.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'pump_prysm_l10n.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await SettingsService().init();
  });

  testWidgets('the privacy screen explains both invite modes', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final l10n = lookupAppLocalizations(const Locale('en'));

    await pumpWithPrysmL10n(
      tester,
      PrivacySettingsScreen(onClose: () {}, keyManager: KeyManager()),
    );

    for (final mode in GroupInviteMode.values) {
      expect(find.text(mode.localizedLabel(l10n)), findsOneWidget);
      expect(find.text(mode.localizedDescription(l10n)), findsOneWidget);
    }
  });

  testWidgets('a panic session cannot reach the invite mode rows',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final l10n = lookupAppLocalizations(const Locale('en'));

    await pumpWithPrysmL10n(
      tester,
      PrivacySettingsScreen(onClose: () {}),
    );

    for (final mode in GroupInviteMode.values) {
      expect(find.text(mode.localizedLabel(l10n)), findsNothing);
    }
  });

  testWidgets('refuse non-contacts toggle is offered and persists',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final l10n = lookupAppLocalizations(const Locale('en'));

    await pumpWithPrysmL10n(
      tester,
      PrivacySettingsScreen(onClose: () {}, keyManager: KeyManager()),
    );

    final row = find.widgetWithText(
      PrysmSwitchRow,
      l10n.refuseMessagesFromNonContacts,
    );
    expect(row, findsOneWidget);
    expect(SettingsService().refuseUnknownSenders, isFalse);
  });
}
