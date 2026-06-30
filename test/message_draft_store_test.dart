import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/models/reply_preview_data.dart';
import 'package:prysm/services/message_draft_store.dart';

void main() {
  setUp(MessageDraftStore.instance.clearAll);

  test('empty store returns empty draft', () {
    expect(MessageDraftStore.instance.get('dm:peer.onion').isEmpty, isTrue);
  });

  test('setText upserts text', () {
    MessageDraftStore.instance.setText('dm:peer.onion', 'hello');
    expect(MessageDraftStore.instance.get('dm:peer.onion').text, 'hello');
  });

  test('setReply upserts reply', () {
    const reply = ReplyPreviewData(
      messageId: 'msg-1',
      authorId: 'peer.onion',
      label: 'Hi',
      kind: ReplyPreviewKind.text,
    );
    MessageDraftStore.instance.setReply('dm:peer.onion', reply);
    expect(MessageDraftStore.instance.get('dm:peer.onion').reply, reply);
  });

  test('setText and setReply are independent', () {
    const reply = ReplyPreviewData(
      messageId: 'msg-1',
      authorId: 'peer.onion',
      label: 'Hi',
      kind: ReplyPreviewKind.text,
    );
    MessageDraftStore.instance.setText('dm:peer.onion', 'draft');
    MessageDraftStore.instance.setReply('dm:peer.onion', reply);

    final draft = MessageDraftStore.instance.get('dm:peer.onion');
    expect(draft.text, 'draft');
    expect(draft.reply, reply);
  });

  test('key removed when text and reply are empty', () {
    MessageDraftStore.instance.setText('dm:peer.onion', 'hello');
    MessageDraftStore.instance.setText('dm:peer.onion', '');
    expect(MessageDraftStore.instance.get('dm:peer.onion').isEmpty, isTrue);
  });

  test('clear removes draft', () {
    MessageDraftStore.instance.setText('dm:peer.onion', 'hello');
    MessageDraftStore.instance.clear('dm:peer.onion');
    expect(MessageDraftStore.instance.get('dm:peer.onion').isEmpty, isTrue);
  });

  test('clearAll removes all drafts', () {
    MessageDraftStore.instance.setText('dm:a.onion', 'one');
    MessageDraftStore.instance.setText('dm:b.onion', 'two');
    MessageDraftStore.instance.clearAll();
    expect(MessageDraftStore.instance.get('dm:a.onion').isEmpty, isTrue);
    expect(MessageDraftStore.instance.get('dm:b.onion').isEmpty, isTrue);
  });
}
