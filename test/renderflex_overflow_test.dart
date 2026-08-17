// Widget tests for the bottom RenderFlex overflows seen on a real Android
// device (prysm_chat.log, 2026-08-09): "A RenderFlex overflowed by 34 pixels
// on the bottom" ~6s after app start, and three "overflowed by 18 pixels on
// the bottom" during an active 1:1 chat.
//
// The log does not capture the widget tree, so the suspects are reproduced
// structurally from the screens active at those moments:
//  - app startup: the PIN unlock screen (fixed-height centered column that
//    ends with a 400px keypad, plus biometric button and Tor progress);
//  - active chat: the composer column at the bottom of the chat body. The
//    body is `Column [ Expanded(list), composer ]` (chat.dart:1758-1810) and
//    the whole app is padded by the keyboard inset in PrysmApp's builder
//    (prysm_app.dart:47-51), so with the keyboard open the composer's fixed
//    intrinsic height (reply preview + typing bar + input row) can exceed the
//    body's remaining height and overflow the outer Column.
//
// ChatScreen itself is not pumpable in a widget test (its initState drives
// ChatService/sqflite, the same hang documented for
// group_invite_mode_screens_test.dart and HANDOFF.md), so the chat tests pump
// the body layout with the real shared widgets: the fixed-structure test
// builds the exact `LayoutBuilder -> Column [ Expanded(list),
// PrysmConstrainedComposer ]` body the 1:1, group and self chat screens
// share (lib/ui/chat/prysm_constrained_composer.dart), and the pre-fix test
// pumps the real PrysmChatComposerColumn as a plain non-flex Column child to
// prove that same setup overflows without the wrapper. The PIN test pumps the
// real PinScreen.
//
// Style follows quoted_reply_preview_test.dart / view_once_image_screen_test.dart:
// testWidgets/pumpWidget with a hand-resolved PrysmStyleScope.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/l10n/app_localizations.dart';
import 'package:prysm/models/appearance_settings.dart';
import 'package:prysm/models/locale_override.dart';
import 'package:prysm/models/reply_preview_data.dart';
import 'package:prysm/screens/onboarding/onboarding_screen.dart';
import 'package:prysm/screens/pin_entry.dart';
import 'package:prysm/screens/widgets/pin_keypad.dart';
import 'package:prysm/screens/widgets/quoted_reply_preview.dart';
import 'package:prysm/services/settings_service.dart';
import 'package:prysm/services/unlock_lockout_service.dart';
import 'package:prysm/theme/prysm_style_resolver.dart';
import 'package:prysm/theme/prysm_style_scope.dart';
import 'package:prysm/ui/chat/prysm_chat_composer_column.dart';
import 'package:prysm/ui/chat/prysm_constrained_composer.dart';
import 'package:prysm/ui/prysm_scaffold.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'pump_prysm_l10n.dart';

Widget wrapWithStyle(Widget child) {
  final style = PrysmStyleResolver.resolve(
    themePalette: 0,
    appearance: const AppearanceSettings(),
  );
  return PrysmStyleScope(style: style, child: child);
}

/// Pumps a chat body the way ChatScreen.build does (chat.dart:1761-1810)
/// inside PrysmApp's keyboard-inset padding (prysm_app.dart:47-51).
///
/// [wrapBody] lets the test exercise both the pre-fix structure (composer as
/// a plain non-flex child of the body Column) and the fixed structure (the
/// shared [PrysmConstrainedComposer] the 1:1, group and self chat screens
/// build, constrained to the body's remaining height and scrollable).
Future<void> pumpChatBody(
  WidgetTester tester, {
  required Widget Function(Widget list, Widget composer) wrapBody,
  required double logicalWidth,
  required double logicalHeight,
  required double keyboardInset,
}) async {
  tester.view.physicalSize = Size(logicalWidth * 3, logicalHeight * 3);
  tester.view.devicePixelRatio = 3.0;
  tester.view.viewInsets = FakeViewPadding(bottom: keyboardInset * 3);
  addTearDown(tester.view.reset);

  final composer = PrysmChatComposerColumn(
    draftKey: 'overflow-test',
    replyPreview: QuotedReplyPreview(
      data: const ReplyPreviewData(
        messageId: '1',
        authorId: 'a',
        label: 'A quoted message that wraps onto two lines',
        kind: ReplyPreviewKind.text,
      ),
      isSentByMe: false,
      authorName: 'Alice',
    ),
    typingTypistNames: const ['Alice'],
    onSendText: (_) {},
    onSendImage: () {},
    onSendFile: () {},
  );
  final list = ListView.builder(
    itemCount: 0,
    itemBuilder: (_, _) => const SizedBox.shrink(),
  );

  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('en'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      home: Builder(
        builder: (context) {
          final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
          return AnimatedPadding(
            padding: EdgeInsets.only(bottom: bottomInset),
            duration: const Duration(milliseconds: 100),
            curve: Curves.easeOut,
            child: wrapWithStyle(
              PrysmPage(
                headerHeight: 70,
                title: 'Peer',
                body: wrapBody(list, composer),
              ),
            ),
          );
        },
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 120));
}

void main() {
  testWidgets(
    'the pre-fix chat body overflows with keyboard + reply + typing bar '
    '(reproduces the device error)',
    (tester) async {
      // MessageComposer constructs AudioRecorder, which pings the record
      // method channel in its constructor (record_platform_interface
      // RecordMethodChannel.create); a no-op handler keeps the test hermetic.
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('com.llfbandit.record/messages'),
        (call) async => null,
      );

      // 360x496 with a 300px keyboard leaves 126px for the body under the
      // 70px header — the composer (reply preview + typing bar + input row)
      // is taller than that, exactly like the device errors.
      await pumpChatBody(
        tester,
        logicalWidth: 360,
        logicalHeight: 496,
        keyboardInset: 300,
        wrapBody: (list, composer) => Column(
          children: [
            Expanded(child: list),
            composer,
          ],
        ),
      );

      final exc = tester.takeException();
      expect(exc, isA<FlutterError>());
      // Assert that the composer overflowed the bottom of the body Column —
      // not the exact pixel count, which depends on font metrics and surface
      // size (the device log reported 18px; the count is not a contract).
      expect(exc.toString(), contains('A RenderFlex overflowed by'));
      expect(exc.toString(), contains('pixels on the bottom'));
    },
  );

  testWidgets(
    'chat composer with reply preview and typing bar fits above the keyboard '
    'through the shared PrysmConstrainedComposer the 1:1/group/self chat '
    'screens build (the fix)',
    (tester) async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('com.llfbandit.record/messages'),
        (call) async => null,
      );

      await pumpChatBody(
        tester,
        logicalWidth: 360,
        logicalHeight: 496,
        keyboardInset: 300,
        wrapBody: (list, composer) => LayoutBuilder(
          builder: (context, constraints) => Column(
            children: [
              Expanded(child: list),
              PrysmConstrainedComposer(
                maxHeight: constraints.maxHeight,
                composer: composer,
              ),
            ],
          ),
        ),
      );

      expect(tester.takeException(), isNull,
          reason: 'composer must not overflow the chat body above the keyboard');
    },
  );

  testWidgets(
    'PIN unlock screen fits on a small screen (360x640) with biometrics and '
    'Tor progress',
    (tester) async {
      UnlockLockoutService.setUseInMemoryStorageOnly(true);
      // Process-global: restore it so the mode does not depend on this test
      // being last in the file.
      addTearDown(() => UnlockLockoutService.setUseInMemoryStorageOnly(false));
      tester.view.physicalSize = const Size(360 * 3, 640 * 3);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      await pumpWithPrysmL10n(
        tester,
        PinScreen(
          onVerifyPin: (_) async => true,
          isPinSet: Future.value(true),
          showBiometricButton: true,
          onTryBiometric: () {},
          torBootstrapProgress: 45,
        ),
        width: 360,
      );

      expect(tester.takeException(), isNull,
          reason: 'PIN screen column must fit on a small phone screen');
    },
  );

  testWidgets(
    'onboarding unlock setup step (2/7) fits 1080x2340: the 0 key is fully '
    'visible at scroll offset 0',
    (tester) async {
      // 1080x2340 @3x — the device the step cut the bottom row on. The step's
      // SingleChildScrollView swallows any overflow, so the assertion is
      // geometry, not an exception.
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      SharedPreferences.setMockInitialValues({});
      final settings = SettingsService();
      await settings.init();
      await settings.setLocaleOverride(LocaleOverride.en);
      final l10n = lookupAppLocalizations(const Locale('en'));

      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          home: wrapWithStyle(
            OnboardingScreen(
              onionAddress: 'abc',
              torReady: true,
              onComplete: () {},
              isInitialSetup: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10n.next));
      await tester.pumpAndSettle();

      final scrollView = find.ancestor(
        of: find.text('0'),
        matching: find.byType(SingleChildScrollView),
      );
      expect(scrollView, findsOneWidget);
      expect(
        tester.getRect(find.text('0')).bottom,
        lessThanOrEqualTo(tester.getRect(scrollView).bottom),
        reason: 'the 0 key must sit above the fold at scroll offset 0',
      );
      // The digit font scales down with the key so a shrunken key is not
      // mostly padding.
      expect(tester.widget<Text>(find.text('1')).style?.fontSize,
          lessThan(32));
    },
  );

  testWidgets(
    'PinPadScreen does not overflow its non-scrollable column on a short '
    'phone (1080x1800 @3x)',
    (tester) async {
      // The 1080x2340 surface never overflowed even before the fix, so it
      // cannot catch a regression; 1080x1800 @3x is the shortest real phone
      // class where the fixed 400dp keypad overflowed the centered column.
      tester.view.physicalSize = const Size(1080, 1800);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          home: wrapWithStyle(
            PinPadScreen(
              title: 'Current PIN',
              subtitle: 'Enter your current unlock PIN.',
              validatePin: (_) async => null,
            ),
          ),
        ),
      );
      await tester.pump();

      expect(tester.takeException(), isNull,
          reason: 'PIN pad column must fit on a short phone screen');
    },
  );

  testWidgets(
    'PinKeypad keeps the exact 80px keys / 10px gaps on a tall surface '
    '(no-op where it already fit)',
    (tester) async {
      tester.view.physicalSize = const Size(1080, 3600);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          home: wrapWithStyle(
            Center(
              child: PinKeypad(onKeyPress: (_) {}),
            ),
          ),
        ),
      );
      await tester.pump();

      final key1 = find
          .ancestor(of: find.text('1'), matching: find.byType(SizedBox))
          .first;
      final key4 = find
          .ancestor(of: find.text('4'), matching: find.byType(SizedBox))
          .first;
      expect(tester.getSize(key1), const Size(80, 80));
      expect(tester.getSize(key4), const Size(80, 80));
      // Each row carries 10 of vertical padding above and below.
      expect(tester.getRect(key4).top - tester.getRect(key1).bottom, 20);
      expect(tester.getSize(find.byType(PinKeypad)), const Size(360, 400));
      // 80dp key keeps the original 32dp digit.
      expect(tester.widget<Text>(find.text('1')).style?.fontSize, 32);
    },
  );
}
