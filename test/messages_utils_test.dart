import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/database/messages.dart';

void main() {
  test('scopedId prefixes group messages', () {
    expect(
      MessagesDb.scopedId(wireId: 'abc', groupId: 'group-1'),
      'group-1::abc',
    );
    expect(MessagesDb.scopedId(wireId: 'abc'), 'abc');
  });

  test('wireIdFromStorage strips group prefix', () {
    expect(MessagesDb.wireIdFromStorage('group-1::abc'), 'abc');
    expect(MessagesDb.wireIdFromStorage('abc'), 'abc');
  });

  test('previewLabelForType maps media types', () {
    expect(MessagesDb.previewLabelForType('image'), '📷 Photo');
    expect(MessagesDb.previewLabelForType('group_audio'), '🎤 Voice');
    expect(MessagesDb.previewLabelForType('group_text'), 'Message');
    expect(MessagesDb.previewLabelForType(null), 'Message');
  });
}
