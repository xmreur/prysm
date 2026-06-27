import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/models/reply_preview_data.dart';
import 'package:prysm/screens/widgets/quoted_reply_preview.dart';

void main() {
  testWidgets('QuotedReplyPreview shows author and label', (tester) async {
    var tapped = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: QuotedReplyPreview(
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
          body: QuotedReplyPreview(
            data: ReplyPreviewData.unavailable,
            isSentByMe: false,
            onTap: () => tapped = true,
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
