import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/models/appearance_settings.dart';
import 'package:prysm/models/reply_preview_data.dart';
import 'package:prysm/screens/widgets/quoted_reply_preview.dart';
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
  testWidgets('QuotedReplyPreview shows author and label', (tester) async {
    var tapped = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: wrapWithStyle(
            QuotedReplyPreview(
              data: const ReplyPreviewData(
                messageId: '1',
                authorId: 'a',
                label: 'Hello',
                kind: ReplyPreviewKind.text,
              ),
              isSentByMe: false,
              authorName: 'Alice',
              onTap: () => tapped = true,
            ),
          ),
        ),
      ),
    );

    expect(find.text('Alice'), findsOneWidget);
    expect(find.text('Hello'), findsOneWidget);

    await tester.tap(find.text('Hello'));
    await tester.pump();
    expect(tapped, isTrue);
  });

  testWidgets('QuotedReplyPreview unavailable state is not tappable', (tester) async {
    var tapped = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: wrapWithStyle(
            QuotedReplyPreview(
              data: ReplyPreviewData.unavailable,
              isSentByMe: false,
              onTap: () => tapped = true,
            ),
          ),
        ),
      ),
    );

    expect(find.text('Original message unavailable'), findsOneWidget);
    await tester.tap(find.text('Original message unavailable'));
    await tester.pump();
    expect(tapped, isFalse);
  });
}
