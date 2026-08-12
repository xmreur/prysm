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
import 'package:prysm/ui/core/prysm_icons.dart';
import 'package:prysm/ui/prysm_search_field.dart';

Widget wrapWithStyle(Widget child) {
  final style = PrysmStyleResolver.resolve(
    themePalette: 0,
    appearance: const AppearanceSettings(),
  );
  return PrysmStyleScope(style: style, child: child);
}

Future<void> pumpInPrysmApp(
  WidgetTester tester,
  Widget child, {
  double width = 320,
}) async {
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
        home: Center(child: SizedBox(width: width, child: child)),
      ),
    ),
  );
}

EditableTextState editableState(WidgetTester tester) =>
    tester.state<EditableTextState>(find.byType(EditableText));

ContextMenuButtonItem buttonItem(
  String label, {
  ContextMenuButtonType type = ContextMenuButtonType.custom,
  VoidCallback? onPressed,
}) {
  return ContextMenuButtonItem(
    onPressed: onPressed ?? () {},
    type: type,
    label: label,
  );
}

/// The standard cut/copy/paste/select-all set EditableText reports on Android.
List<ContextMenuButtonItem> standardItems() => [
      ContextMenuButtonItem(onPressed: () {}, type: ContextMenuButtonType.cut),
      ContextMenuButtonItem(onPressed: () {}, type: ContextMenuButtonType.copy),
      ContextMenuButtonItem(
        onPressed: () {},
        type: ContextMenuButtonType.paste,
      ),
      ContextMenuButtonItem(
        onPressed: () {},
        type: ContextMenuButtonType.selectAll,
      ),
    ];

/// The standard four actions plus the Android PROCESS_TEXT extras the bug
/// report showed (installed apps arrive as `.custom` with a label).
List<ContextMenuButtonItem> itemsWithOverflow() => [
      ...standardItems(),
      ContextMenuButtonItem(
        onPressed: () {},
        type: ContextMenuButtonType.share,
      ),
      buttonItem('Translate'),
      buttonItem('Read aloud'),
    ];

/// Pumps the toolbar directly with a hand-built item list. The surface is
/// wider than a test's default 800x600 so the Ahem test font (every glyph a
/// 15px square) still fits the primaries plus the more button on one row.
Future<void> pumpToolbar(
  WidgetTester tester,
  List<ContextMenuButtonItem> items, {
  double width = 600,
}) async {
  await tester.binding.setSurfaceSize(Size(width, 800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await pumpInPrysmApp(
    tester,
    PrysmTextSelectionToolbar(
      anchors: const TextSelectionToolbarAnchors(
        primaryAnchor: Offset(300, 120),
      ),
      buttonItems: items,
    ),
    width: width,
  );
}

/// Rebuilds the toolbar in place across pumps, the way a new selection does:
/// the same element receives a new [buttonItems] list, so `didUpdateWidget`
/// runs instead of a fresh State being created.
class ToolbarHarness extends StatefulWidget {
  const ToolbarHarness({required this.items, super.key});

  final List<ContextMenuButtonItem> items;

  @override
  State<ToolbarHarness> createState() => _ToolbarHarnessState();
}

class _ToolbarHarnessState extends State<ToolbarHarness> {
  @override
  Widget build(BuildContext context) {
    return PrysmTextSelectionToolbar(
      anchors: const TextSelectionToolbarAnchors(
        primaryAnchor: Offset(300, 120),
      ),
      buttonItems: widget.items,
    );
  }
}

Future<void> pumpHarness(
  WidgetTester tester,
  List<ContextMenuButtonItem> items, {
  double width = 600,
}) async {
  await tester.binding.setSurfaceSize(Size(width, 800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await pumpInPrysmApp(tester, ToolbarHarness(items: items), width: width);
}

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

  // --- overflow folding (Android PROCESS_TEXT entries) -------------------

  testWidgets('more than four items show the primaries and a more button, '
      'folding the rest away', (tester) async {
    await pumpToolbar(tester, itemsWithOverflow());

    for (final label in ['Cut', 'Copy', 'Paste', 'Select all']) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.byIcon(PrysmIcons.more), findsOneWidget);
    for (final label in ['Share', 'Translate', 'Read aloud']) {
      expect(find.text(label), findsNothing,
          reason: 'overflow actions stay folded behind the more button');
    }
  }, variant: onAndroid);

  testWidgets('the more button opens the overflow page and the back chevron '
      'closes it', (tester) async {
    await pumpToolbar(tester, itemsWithOverflow());

    await tester.tap(find.byIcon(PrysmIcons.more));
    await tester.pumpAndSettle();

    expect(find.byIcon(PrysmIcons.chevronLeft), findsOneWidget);
    for (final label in ['Share', 'Translate', 'Read aloud']) {
      expect(find.text(label), findsOneWidget);
    }
    for (final label in ['Cut', 'Copy', 'Paste', 'Select all']) {
      expect(find.text(label), findsNothing);
    }

    await tester.tap(find.byIcon(PrysmIcons.chevronLeft));
    await tester.pumpAndSettle();

    expect(find.byIcon(PrysmIcons.chevronLeft), findsNothing);
    for (final label in ['Cut', 'Copy', 'Paste', 'Select all']) {
      expect(find.text(label), findsOneWidget);
    }
    for (final label in ['Share', 'Translate', 'Read aloud']) {
      expect(find.text(label), findsNothing);
    }
  }, variant: onAndroid);

  testWidgets('tapping an overflow item invokes its onPressed',
      (tester) async {
    var translateTapped = false;
    await pumpToolbar(
      tester,
      [
        ...standardItems(),
        buttonItem('Translate', onPressed: () => translateTapped = true),
      ],
    );

    await tester.tap(find.byIcon(PrysmIcons.more));
    await tester.pumpAndSettle();

    expect(translateTapped, isFalse);
    await tester.tap(find.text('Translate'));
    await tester.pumpAndSettle();
    expect(translateTapped, isTrue);
  }, variant: onAndroid);

  testWidgets('exactly the standard four items render no more button',
      (tester) async {
    await pumpToolbar(tester, standardItems());

    for (final label in ['Cut', 'Copy', 'Paste', 'Select all']) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.byIcon(PrysmIcons.more), findsNothing);
  }, variant: onAndroid);

  testWidgets('the collapsed page keeps the primaries and the more button on '
      'a single row', (tester) async {
    await pumpToolbar(tester, itemsWithOverflow());

    final rowTop = tester.getTopLeft(find.text('Cut')).dy;
    for (final label in ['Copy', 'Paste', 'Select all']) {
      expect(tester.getTopLeft(find.text(label)).dy, rowTop,
          reason: '$label sits on the same row as Cut');
    }
    expect(
      tester.getTopLeft(find.byIcon(PrysmIcons.more)).dy,
      closeTo(rowTop, 2),
      reason: 'the more button sits beside the primaries, not below them',
    );

    final oneRowHeight = tester.getSize(find.text('Cut')).height +
        const EdgeInsets.symmetric(horizontal: 14, vertical: 11).vertical;
    expect(
      tester.getSize(find.byType(Wrap)).height,
      lessThan(oneRowHeight * 1.5),
      reason: 'one row of items, not a wrapped stack',
    );
  }, variant: onAndroid);

  testWidgets('a different item set closes the open overflow page',
      (tester) async {
    await pumpHarness(tester, itemsWithOverflow());
    await tester.tap(find.byIcon(PrysmIcons.more));
    await tester.pumpAndSettle();
    expect(find.text('Translate'), findsOneWidget);

    // A new selection reuses the same element with a different button list —
    // here one with overflow actions of its own, which must not show stale.
    await pumpHarness(
      tester,
      [
        ...standardItems(),
        buttonItem('Ask Meta AI'),
        buttonItem('Ask ChatGPT'),
      ],
    );
    expect(find.byIcon(PrysmIcons.more), findsOneWidget);
    for (final label in ['Ask Meta AI', 'Ask ChatGPT', 'Translate']) {
      expect(find.text(label), findsNothing,
          reason: 'a different item set must fall back to the collapsed page');
    }
  }, variant: onAndroid);

  testWidgets('rebuilding with the same labels keeps the overflow page open',
      (tester) async {
    await pumpHarness(tester, itemsWithOverflow());
    await tester.tap(find.byIcon(PrysmIcons.more));
    await tester.pumpAndSettle();
    expect(find.text('Translate'), findsOneWidget);

    // The toolbar rebuilds while open (e.g. the clipboard status flipping
    // Paste on/off); the labels are unchanged, so the page must stay open.
    await pumpHarness(tester, itemsWithOverflow());
    expect(find.text('Translate'), findsOneWidget);
    expect(find.text('Cut'), findsNothing);
  }, variant: onAndroid);

  testWidgets('a long PROCESS_TEXT list is capped at a third of the screen',
      (tester) async {
    await pumpToolbar(
      tester,
      [
        ...standardItems(),
        for (var i = 0; i < 25; i++) buttonItem('Action $i'),
      ],
    );
    await tester.tap(find.byIcon(PrysmIcons.more));
    await tester.pumpAndSettle();

    final page = find.descendant(
      of: find.byType(PrysmTextSelectionToolbar),
      matching: find.byType(SingleChildScrollView),
    );
    expect(page, findsOneWidget);
    final media = MediaQuery.of(
      tester.element(find.byType(PrysmTextSelectionToolbar)),
    );
    expect(
      tester.getSize(page).height,
      lessThanOrEqualTo(media.size.height / 3 + 1),
      reason: 'an arbitrarily long PROCESS_TEXT list must never run off '
          'screen',
    );
  }, variant: onAndroid);

}
