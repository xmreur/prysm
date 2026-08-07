// Widget test for the group-invite-mode setting UI.
// Style follows view_once_image_screen_test.dart (hand-resolved
// PrysmStyleScope, no app bootstrap).
//
// It defends a requirement, not an implementation detail: the privacy
// screen must state what BOTH modes imply before the user picks one — the
// whole reason the setting is two radio rows with descriptions instead of a
// switch or a bottom sheet. A tidy-up that drops the subtitles would
// silently remove the informed part of an informed choice.
//
// The requests screen is NOT covered here on purpose. Its first frame is a
// PrysmProgressIndicator and its content arrives from a real sqflite read in
// initState; under testWidgets' fake-async zone that future never completes,
// so any assertion on the list would hang rather than fail. It is verified
// on the running desktop app instead.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/models/appearance_settings.dart';
import 'package:prysm/models/group_invite_mode.dart';
import 'package:prysm/screens/privacy_settings_screen.dart';
import 'package:prysm/theme/prysm_style_resolver.dart';
import 'package:prysm/theme/prysm_style_scope.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget wrapWithStyle(Widget child) {
  final style = PrysmStyleResolver.resolve(
    themePalette: 0,
    appearance: const AppearanceSettings(),
  );
  return PrysmStyleScope(
    style: style,
    child: MaterialApp(home: child),
  );
}

void main() {
  testWidgets('the privacy screen explains both invite modes', (tester) async {
    SharedPreferences.setMockInitialValues({});

    await tester.pumpWidget(
      wrapWithStyle(
        PrivacySettingsScreen(onClose: () {}, keyManager: KeyManager()),
      ),
    );
    await tester.pumpAndSettle();

    for (final mode in GroupInviteMode.values) {
      expect(
        find.text(mode.label),
        findsOneWidget,
        reason: 'the ${mode.name} row must be offered',
      );
      expect(
        find.text(mode.description),
        findsOneWidget,
        reason: 'the ${mode.name} row must say what it implies',
      );
    }
  });

  testWidgets('a panic session cannot reach the invite mode rows',
      (tester) async {
    SharedPreferences.setMockInitialValues({});

    // The home screen passes keyManager: null in decoy mode, so the rows
    // must not exist: a panic session must not change the real policy.
    await tester.pumpWidget(
      wrapWithStyle(PrivacySettingsScreen(onClose: () {})),
    );
    await tester.pumpAndSettle();

    for (final mode in GroupInviteMode.values) {
      expect(
        find.text(mode.label),
        findsNothing,
        reason: 'the ${mode.name} row must not be offered without a key '
            'manager',
      );
    }
  });
}
