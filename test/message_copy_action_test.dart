// Guards the shared 'Copy' action of the message menus.
//
// Long-pressing a message opened an action sheet with no Copy row in the group
// chat and in the self-chat: only the 1:1 chat had one, because the sheet was
// written three times instead of once. That is half of the reported defect
// ("hold down and you get no copy menu"); the other half — selection inside the
// composer — is covered by prysm_text_selection_test.dart.
//
// The three screens themselves are not pumpable (their initState drives
// ChatService/sqflite; see HANDOFF.md and group_invite_mode_screens_test.dart),
// so the seam under test is the shared tile they now all build. That the three
// screens actually call it was verified on the running app, not here.
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/models/appearance_settings.dart';
import 'package:prysm/models/chat/prysm_message.dart';
import 'package:prysm/screens/widgets/message_copy_action.dart';
import 'package:prysm/theme/prysm_style_resolver.dart';
import 'package:prysm/theme/prysm_style_scope.dart';

Widget wrapWithStyle(Widget child) {
  final style = PrysmStyleResolver.resolve(
    themePalette: 0,
    appearance: const AppearanceSettings(),
  );
  return PrysmStyleScope(style: style, child: child);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('messageCopyText', () {
    test('a text message copies its body', () {
      expect(
        messageCopyText(
          PrysmTextMessage(id: 'm1', authorId: 'a', text: 'axolotl dossier'),
        ),
        'axolotl dossier',
      );
    });

    test('a file message copies its name, not its source path', () {
      expect(
        messageCopyText(
          PrysmFileMessage(
            id: 'm2',
            authorId: 'a',
            name: 'report.pdf',
            source: 'blob:deadbeef',
            size: 12,
          ),
        ),
        'report.pdf',
      );
    });

    test('an image message copies a placeholder, never its source', () {
      final text = messageCopyText(
        PrysmImageMessage(
          id: 'm3',
          authorId: 'a',
          source: 'blob:deadbeef',
          size: 12,
        ),
      );
      expect(text, '📷 Image');
      expect(text.contains('blob:'), isFalse);
    });

    test('a call message has no copy text — its label belongs to the '
        'screen that renders it', () {
      expect(
        messageCopyText(
          PrysmCallMessage(
            id: 'm4',
            authorId: 'a',
            direction: 'outbound',
            callStatus: 'completed',
            durationMs: 1000,
          ),
        ),
        '',
      );
    });
  });

  testWidgets('the Copy tile writes the message text to the clipboard',
      (tester) async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );

    await tester.pumpWidget(
      wrapWithStyle(
        WidgetsApp(
          color: const Color(0xFF000000),
          pageRouteBuilder: <T>(RouteSettings settings, WidgetBuilder builder) =>
              PageRouteBuilder<T>(
            settings: settings,
            pageBuilder: (context, animation, secondaryAnimation) =>
                builder(context),
          ),
          home: Builder(
            builder: (context) =>
                copyMessageTile(context: context, text: 'axolotl dossier'),
          ),
        ),
      ),
    );

    expect(find.text('Copy'), findsOneWidget);
    await tester.tap(find.text('Copy'));
    await tester.pump();

    // The row also confirms the copy, and showPrysmToast holds a 3s
    // Future.delayed to pull its overlay entry: the binding fails the test on
    // any timer that outlives the tree, so it has to be drained here.
    expect(find.text('Copied to clipboard'), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));

    final setData =
        calls.where((call) => call.method == 'Clipboard.setData').toList();
    expect(setData, hasLength(1));
    expect((setData.single.arguments as Map)['text'], 'axolotl dossier');
  });
}
