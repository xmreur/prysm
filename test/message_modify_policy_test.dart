import 'package:flutter_chat_core/flutter_chat_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/util/message_modify_policy.dart';

void main() {
  TextMessage msg({
    required String authorId,
    DateTime? createdAt,
    Map<String, Object?>? metadata,
  }) {
    return TextMessage(
      authorId: authorId,
      createdAt: createdAt ?? DateTime.now(),
      id: 'm1',
      text: 'hello',
      metadata: metadata,
    );
  }

  test('can edit own text message within five minutes', () {
    final message = msg(
      authorId: 'me',
      createdAt: DateTime.now().subtract(const Duration(minutes: 2)),
    );
    expect(canEditMessage(message, 'me'), isTrue);
  });

  test('cannot edit after five minutes', () {
    final message = msg(
      authorId: 'me',
      createdAt: DateTime.now().subtract(const Duration(minutes: 6)),
    );
    expect(canEditMessage(message, 'me'), isFalse);
  });

  test('cannot edit peer messages', () {
    final message = msg(authorId: 'peer');
    expect(canEditMessage(message, 'me'), isFalse);
  });

  test('deleted messages are marked in metadata', () {
    final deleted = markMessageDeleted(
      msg(authorId: 'me', metadata: const {'edited': true}),
    );
    expect(isMessageDeleted(deleted), isTrue);
    expect(deleted.metadata?['edited'], isTrue);
  });
}
