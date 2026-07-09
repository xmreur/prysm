import 'package:prysm/models/chat/prysm_message.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/constants/group_constants.dart';
import 'package:prysm/models/reply_preview_data.dart';
import 'package:prysm/util/reply_preview_label.dart';

void main() {
  test('replyPreviewFromMessage maps text messages', () {
    final data = replyPreviewFromMessage(
      TextMessage(
        id: '1',
        authorId: 'a',
        createdAt: DateTime.now(),
        text: 'Hello there',
      ),
    );
    expect(data.kind, ReplyPreviewKind.text);
    expect(data.label, 'Hello there');
  });

  test('replyPreviewFromMessage maps deleted messages', () {
    final data = replyPreviewFromMessage(
      TextMessage(
        id: '1',
        authorId: 'a',
        createdAt: DateTime.now(),
        text: '',
        metadata: const {'deleted': true},
      ),
    );
    expect(data.kind, ReplyPreviewKind.deleted);
    expect(data.label, 'Deleted');
  });

  test('replyPreviewFromMessage maps voice file messages', () {
    final data = replyPreviewFromMessage(
      FileMessage(
        id: '1',
        authorId: 'a',
        createdAt: DateTime.now(),
        name: 'voice_message.wav',
        size: 10,
        source: 'audio:1000:/tmp/x.wav',
      ),
    );
    expect(data.kind, ReplyPreviewKind.voice);
    expect(data.label, 'Voice message');
  });

  test('replyPreviewFromDbRow maps media and deleted rows', () {
    final voice = replyPreviewFromDbRow({
      'id': 'grp::v1',
      'senderId': 'peer',
      'type': groupAudioType,
      'fileName': 'voice_message.wav',
      'message': 'cipher',
    });
    expect(voice.kind, ReplyPreviewKind.voice);
    expect(voice.messageId, 'v1');

    final deleted = replyPreviewFromDbRow({
      'id': 'm1',
      'senderId': 'peer',
      'type': 'image',
      'deletedAt': 123,
      'message': '',
    });
    expect(deleted.kind, ReplyPreviewKind.deleted);

    final image = replyPreviewFromDbRow({
      'id': 'm2',
      'senderId': 'peer',
      'type': groupImageType,
      'message': 'cipher',
    });
    expect(image.kind, ReplyPreviewKind.image);
    expect(image.label, 'Photo');
  });
}
