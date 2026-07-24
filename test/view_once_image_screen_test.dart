// Widget tests for the single shared view-once image viewer (Fase 6C) —
// replaces the three screen-local copies (_ViewOnceScreen in chat.dart and
// self_chat_screen.dart, _GroupViewOnceScreen in group_chat.dart). Style
// follows quoted_reply_preview_test.dart (the only pre-existing widget
// test): testWidgets/pumpWidget with a hand-resolved PrysmStyleScope.
//
// Per-variant title/closeColor coverage restores what the review found
// altered: the DM screen showed 'View Once' with a translucent close icon,
// group/self showed no title at all (also translucent), and the media
// gallery — the widget's original sole consumer, untouched by the
// unification — showed 'View once' with a fully opaque close icon. The
// widget defaults to the gallery's values so its call site (no override)
// stays visually unchanged.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/models/appearance_settings.dart';
import 'package:prysm/screens/widgets/view_once_image_screen.dart';
import 'package:prysm/theme/prysm_style_resolver.dart';
import 'package:prysm/theme/prysm_style_scope.dart';
import 'package:prysm/ui/core/prysm_button.dart';
import 'package:prysm/ui/core/prysm_icons.dart';

// 1x1 transparent PNG.
final _pngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk'
  '+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
);

Widget wrapWithStyle(Widget child) {
  final style = PrysmStyleResolver.resolve(
    themePalette: 0,
    appearance: const AppearanceSettings(),
  );
  return PrysmStyleScope(style: style, child: child);
}

Color? _closeButtonColor(WidgetTester tester) {
  return tester.widget<PrysmIconButton>(find.byType(PrysmIconButton)).color;
}

void main() {
  testWidgets('ViewOnceImageScreen defaults match the media gallery variant '
      '(title "View once", opaque close)', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: wrapWithStyle(ViewOnceImageScreen(imageBytes: _pngBytes)),
      ),
    );

    expect(find.text('View once'), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
    expect(find.byIcon(PrysmIcons.close), findsOneWidget);
    expect(_closeButtonColor(tester), const Color(0xFFFFFFFF));
  });

  testWidgets(
    'ViewOnceImageScreen DM variant shows "View Once" with translucent '
    'close',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: wrapWithStyle(
            ViewOnceImageScreen(
              imageBytes: _pngBytes,
              title: 'View Once',
              closeColor: const Color(0xB3FFFFFF),
            ),
          ),
        ),
      );

      expect(find.text('View Once'), findsOneWidget);
      expect(find.text('View once'), findsNothing);
      expect(_closeButtonColor(tester), const Color(0xB3FFFFFF));
    },
  );

  testWidgets('ViewOnceImageScreen group/self variant shows no title with '
      'translucent close', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: wrapWithStyle(
          ViewOnceImageScreen(
            imageBytes: _pngBytes,
            title: null,
            closeColor: const Color(0xB3FFFFFF),
          ),
        ),
      ),
    );

    expect(find.text('View Once'), findsNothing);
    expect(find.text('View once'), findsNothing);
    expect(find.byIcon(PrysmIcons.close), findsOneWidget);
    expect(_closeButtonColor(tester), const Color(0xB3FFFFFF));
  });

  testWidgets('ViewOnceImageScreen close button pops the route', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: wrapWithStyle(
          Builder(
            builder: (context) => GestureDetector(
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) =>
                      wrapWithStyle(ViewOnceImageScreen(imageBytes: _pngBytes)),
                ),
              ),
              child: const Text('open viewer'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open viewer'));
    await tester.pumpAndSettle();
    expect(find.text('View once'), findsOneWidget);

    await tester.tap(find.byIcon(PrysmIcons.close));
    await tester.pumpAndSettle();
    expect(find.text('View once'), findsNothing);
    expect(find.text('open viewer'), findsOneWidget);
  });

  testWidgets('ViewOnceImageScreen forwards the fit parameter', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: wrapWithStyle(
          ViewOnceImageScreen(imageBytes: _pngBytes, fit: BoxFit.contain),
        ),
      ),
    );

    final image = tester.widget<Image>(find.byType(Image));
    expect(image.fit, BoxFit.contain);
  });

  testWidgets('ViewOnceImageScreen fit defaults to null (natural size)', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: wrapWithStyle(ViewOnceImageScreen(imageBytes: _pngBytes)),
      ),
    );

    final image = tester.widget<Image>(find.byType(Image));
    expect(image.fit, isNull);
  });
}
