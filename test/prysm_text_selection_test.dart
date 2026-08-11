// Guards the Material-free text selection wired into every Prysm input.
//
// Before the fix, PrysmTextField and PrysmSearchField built a bare
// EditableText: `selectionColor`, `selectionControls` and `contextMenuBuilder`
// all defaulted to null, so on a phone a long press selected a word that was
// never painted, grew no drag handles and opened no copy/paste menu. That is
// the reported defect ("hold down like on WhatsApp: it does not let you select
// the text, no copy menu").
//
// These tests pump a WidgetsApp — NOT a MaterialApp — on purpose: MaterialApp
// installs its own DefaultSelectionStyle, selection controls and
// AdaptiveTextSelectionToolbar, so a Material-based fix would pass under
// MaterialApp and still be broken in the real app, whose root is
// PrysmApp -> WidgetsApp (lib/ui/core/prysm_app.dart:28).
//
// Style follows quoted_reply_preview_test.dart: a hand-resolved
// PrysmStyleScope around the tree.
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/models/appearance_settings.dart';
import 'package:prysm/theme/prysm_style_resolver.dart';
import 'package:prysm/theme/prysm_style_scope.dart';
import 'package:prysm/ui/core/prysm_text_field.dart';
import 'package:prysm/ui/core/prysm_text_selection.dart';
import 'package:prysm/ui/prysm_search_field.dart';

Widget wrapWithStyle(Widget child) {
  final style = PrysmStyleResolver.resolve(
    themePalette: 0,
    appearance: const AppearanceSettings(),
  );
  return PrysmStyleScope(style: style, child: child);
}

Future<void> pumpInPrysmApp(WidgetTester tester, Widget child) async {
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
        home: Center(child: SizedBox(width: 320, child: child)),
      ),
    ),
  );
}

EditableTextState editableState(WidgetTester tester) =>
    tester.state<EditableTextState>(find.byType(EditableText));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<MethodCall> platformCalls;

  setUp(() {
    platformCalls = <MethodCall>[];
    // The paste button is withheld until the clipboard status is known
    // (EditableText.getEditableButtonItems), and an unmocked channel leaves it
    // `unknown` — which would empty the whole menu.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      platformCalls.add(call);
      return switch (call.method) {
        'Clipboard.hasStrings' => <String, dynamic>{'value': true},
        'Clipboard.getData' => <String, dynamic>{'text': 'clip'},
        _ => null,
      };
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  // The report is about a phone; the override goes through the variant so the
  // binding's debug-variable invariant check stays happy.
  final onAndroid = TargetPlatformVariant.only(TargetPlatform.android);

  testWidgets('long press in a text field selects a word and opens the '
      'Prysm context menu', (tester) async {
    final controller = TextEditingController(text: 'hello world');
    addTearDown(controller.dispose);

    await pumpInPrysmApp(
      tester,
      PrysmTextField(controller: controller),
    );

    expect(find.byType(PrysmTextSelectionToolbar), findsNothing);

    await tester.longPress(find.byType(PrysmEditableText));
    await tester.pumpAndSettle();

    final state = editableState(tester);
    expect(
      state.textEditingValue.selection.isCollapsed,
      isFalse,
      reason: 'a long press must select the word under the finger',
    );
    expect(
      state.textEditingValue.selection.textInside(controller.text),
      'world',
    );

    // The menu, and the two entries the report named.
    expect(find.byType(PrysmTextSelectionToolbar), findsOneWidget);
    expect(find.text('Copy'), findsOneWidget);
    expect(find.text('Paste'), findsOneWidget);

    // The drag handles: without controls the overlay draws none, and without
    // showSelectionHandles it never asks for them.
    expect(state.widget.selectionControls, isA<PrysmTextSelectionControls>());
    expect(state.widget.showSelectionHandles, isTrue);

    // The selection must actually be painted; a null selectionColor is why the
    // pre-fix long press looked like it did nothing at all.
    expect(state.widget.selectionColor, isNotNull);
  }, variant: onAndroid);

  testWidgets('Copy in the context menu puts the selection on the clipboard',
      (tester) async {
    final controller = TextEditingController(text: 'hello world');
    addTearDown(controller.dispose);

    await pumpInPrysmApp(
      tester,
      PrysmTextField(controller: controller),
    );

    await tester.longPress(find.byType(PrysmEditableText));
    await tester.pumpAndSettle();

    platformCalls.clear();
    await tester.tap(find.text('Copy'));
    await tester.pumpAndSettle();

    final setData = platformCalls
        .where((call) => call.method == 'Clipboard.setData')
        .toList();
    expect(setData, hasLength(1));
    expect((setData.single.arguments as Map)['text'], 'world');
  }, variant: onAndroid);

  testWidgets('the search field gets the same selection affordances',
      (tester) async {
    final controller = TextEditingController(text: 'axolotl dossier');
    addTearDown(controller.dispose);

    await pumpInPrysmApp(
      tester,
      PrysmSearchField(controller: controller),
    );

    await tester.longPress(find.byType(PrysmEditableText));
    await tester.pumpAndSettle();

    expect(find.byType(PrysmTextSelectionToolbar), findsOneWidget);
    expect(find.text('Copy'), findsOneWidget);
    expect(
      editableState(tester).widget.selectionControls,
      isA<PrysmTextSelectionControls>(),
    );
  }, variant: onAndroid);

  testWidgets('an obscured field offers no selection, handles or menu',
      (tester) async {
    final controller = TextEditingController(text: '123456');
    addTearDown(controller.dispose);

    await pumpInPrysmApp(
      tester,
      PrysmTextField(controller: controller, obscureText: true),
    );

    await tester.longPress(find.byType(PrysmEditableText));
    await tester.pumpAndSettle();

    // Copying a passphrase out of the field it was typed into is not an
    // affordance we want; EditableText's own default is the same.
    expect(editableState(tester).widget.selectionControls, isNull);
    expect(find.byType(PrysmTextSelectionToolbar), findsNothing);
  }, variant: onAndroid);

  testWidgets('a disabled field offers no selection', (tester) async {
    final controller = TextEditingController(text: 'read only');
    addTearDown(controller.dispose);

    await pumpInPrysmApp(
      tester,
      PrysmTextField(controller: controller, enabled: false),
    );

    await tester.longPress(find.byType(PrysmEditableText));
    await tester.pumpAndSettle();

    expect(editableState(tester).widget.selectionControls, isNull);
    expect(find.byType(PrysmTextSelectionToolbar), findsNothing);
  }, variant: onAndroid);

  testWidgets('the context menu labels every button type without Material '
      'localizations', (tester) async {
    // WidgetsApp installs DefaultWidgetsLocalizations, which has no
    // cut/copy/paste strings: the labels are ours, so every ContextMenuButtonType
    // must map to one or a button renders blank.
    for (final type in ContextMenuButtonType.values) {
      final label = PrysmTextSelectionToolbar.labelFor(
        ContextMenuButtonItem(onPressed: () {}, type: type),
      );
      expect(label, isNotEmpty, reason: 'no label for $type');
    }
    // A platform-supplied action (Android PROCESS_TEXT) carries its own label.
    expect(
      PrysmTextSelectionToolbar.labelFor(
        ContextMenuButtonItem(
          onPressed: () {},
          type: ContextMenuButtonType.custom,
          label: 'Translate',
        ),
      ),
      'Translate',
    );
  });

  // The teardrop point is the painter's local origin; mapping it through the
  // handle's rotation must land on the corner getHandleAnchor reports.
  testWidgets('the teardrop point of every handle lands on its anchor',
      (tester) async {
    final controls = PrysmTextSelectionControls();
    await pumpInPrysmApp(
      tester,
      Builder(
        builder: (context) => Column(
          children: [
            for (final type in TextSelectionHandleType.values)
              KeyedSubtree(
                key: ValueKey(type),
                child: controls.buildHandle(context, type, 20.0),
              ),
          ],
        ),
      ),
    );

    const centre = Offset(10, 10);
    for (final type in TextSelectionHandleType.values) {
      final transform = find.descendant(
        of: find.byKey(ValueKey(type)),
        matching: find.byType(Transform),
      );
      // The right handle is drawn unrotated, so keep the identity matrix.
      var matrix = Matrix4.identity();
      if (transform.evaluate().isNotEmpty) {
        matrix = tester.widget<Transform>(transform).transform;
      }
      final d = Offset.zero - centre;
      final point = centre +
          Offset(
            matrix.storage[0] * d.dx + matrix.storage[4] * d.dy,
            matrix.storage[1] * d.dx + matrix.storage[5] * d.dy,
          );
      // Collapsed is Material's (10,-4) vs the exact (10,-4.142).
      expect(
        (point - controls.getHandleAnchor(type, 20.0)).distance,
        lessThan(0.2),
      );
    }
  });
}
