import 'package:prysm/models/chat/prysm_message.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/models/group.dart';
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

  test('rowShowsAsDeleted only trusts deletedAt, not missing wire', () {
    final meta = <String, Object?>{};
    expect(
      rowShowsAsDeleted({'type': 'text', 'message': 'hello'}, meta),
      isFalse,
    );
    expect(
      rowShowsAsDeleted({'type': 'text'}, meta),
      isFalse,
    );
    expect(
      rowShowsAsDeleted({'type': 'file', 'fileName': 'a.zip'}, meta),
      isFalse,
    );
  });

  test('rowShowsAsDeleted respects deletedAt metadata', () {
    expect(
      rowShowsAsDeleted(
        {'type': 'file', 'deletedAt': 1},
        metadataFromDbRow({'deletedAt': 1}),
      ),
      isTrue,
    );
  });

  test('metadataFromDbRow maps forwarded=1', () {
    expect(metadataFromDbRow({'forwarded': 1})['forwarded'], isTrue);
    expect(metadataFromDbRow({'forwarded': 0})['forwarded'], isNull);
    expect(metadataFromDbRow({})['forwarded'], isNull);
  });

  test('canForwardMessage allows text image file and voice', () {
    expect(
      canForwardMessage(
        TextMessage(id: 't', authorId: 'a', text: 'hi'),
      ),
      isTrue,
    );
    expect(
      canForwardMessage(
        ImageMessage(id: 'i', authorId: 'a', source: 'x', size: 1),
      ),
      isTrue,
    );
    expect(
      canForwardMessage(
        FileMessage(
          id: 'f',
          authorId: 'a',
          name: 'doc.pdf',
          source: 'x',
          size: 1,
        ),
      ),
      isTrue,
    );
    expect(
      canForwardMessage(
        FileMessage(
          id: 'v',
          authorId: 'a',
          name: 'voice_message.wav',
          source: 'x',
          size: 1,
        ),
      ),
      isTrue,
    );
  });

  test('canForwardMessage rejects deleted view-once and call events', () {
    expect(
      canForwardMessage(
        markMessageDeleted(TextMessage(id: 't', authorId: 'a', text: 'hi')),
      ),
      isFalse,
    );
    expect(
      canForwardMessage(
        ImageMessage(
          id: 'i',
          authorId: 'a',
          source: 'x',
          size: 1,
          metadata: const {'viewOnce': true},
        ),
      ),
      isFalse,
    );
    expect(
      canForwardMessage(
        PrysmCallMessage(
          id: 'c',
          authorId: 'a',
          durationMs: 0,
          callStatus: 'missed',
          direction: 'inbound',
        ),
      ),
      isFalse,
    );
  });

  test('canPinMessage matches canForwardMessage', () {
    expect(
      canPinMessage(TextMessage(id: 't', authorId: 'a', text: 'hi')),
      isTrue,
    );
    expect(
      canPinMessage(
        markMessageDeleted(TextMessage(id: 't', authorId: 'a', text: 'hi')),
      ),
      isFalse,
    );
    expect(
      canPinMessage(
        ImageMessage(
          id: 'i',
          authorId: 'a',
          source: 'x',
          size: 1,
          metadata: const {'viewOnce': true},
        ),
      ),
      isFalse,
    );
    expect(
      canPinMessage(
        PrysmCallMessage(
          id: 'c',
          authorId: 'a',
          durationMs: 0,
          callStatus: 'missed',
          direction: 'inbound',
        ),
      ),
      isFalse,
    );
  });

  test('author can always delete for everyone', () {
    final message = msg(authorId: 'me');
    expect(canDeleteForEveryone(message, 'me'), isTrue);
    expect(
      canDeleteForEveryone(
        message,
        'me',
        actorRole: GroupRole.member,
        authorRole: GroupRole.member,
      ),
      isTrue,
    );
  });

  test('group admin can delete a member message, not an owner message', () {
    final memberMsg = msg(authorId: 'member');
    expect(
      canDeleteForEveryone(
        memberMsg,
        'admin',
        actorRole: GroupRole.admin,
        authorRole: GroupRole.member,
      ),
      isTrue,
    );
    expect(
      canDeleteForEveryone(
        memberMsg,
        'admin',
        actorRole: GroupRole.admin,
        authorRole: GroupRole.owner,
      ),
      isFalse,
    );
  });

  test('direct chats still reject non-author deletes', () {
    expect(canDeleteForEveryone(msg(authorId: 'peer'), 'me'), isFalse);
  });

  test('moderation delete requires both actor and author roles', () {
    final memberMsg = msg(authorId: 'member');
    expect(
      canDeleteForEveryone(
        memberMsg,
        'admin',
        actorRole: GroupRole.admin,
      ),
      isFalse,
    );
    expect(
      canDeleteForEveryone(
        memberMsg,
        'admin',
        actorRole: GroupRole.admin,
        authorRole: GroupRole.member,
      ),
      isTrue,
    );
  });
}
