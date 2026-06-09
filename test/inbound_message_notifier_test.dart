import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/util/inbound_message_notifier.dart';

void main() {
  setUp(() {
    InboundMessageNotifier.instance.resetForTest();
  });

  test('notify delivers event to subscriber', () async {
    InboundMessageEvent? received;
    InboundMessageNotifier.instance.onInboundMessage.listen((event) {
      received = event;
    });

    const row = {
      'id': 'peer.onion::msg-1',
      'senderId': 'peer.onion',
      'receiverId': 'me.onion',
      'message': 'cipher',
      'type': 'text',
      'timestamp': 1000,
      'status': 'received',
    };

    InboundMessageNotifier.instance.notify(InboundMessageEvent.fromRow(row));

    await Future<void>.delayed(Duration.zero);
    expect(received, isNotNull);
    expect(received!.senderId, 'peer.onion');
    expect(received!.groupId, isNull);
    expect(received!.row['id'], 'peer.onion::msg-1');
  });

  test('fromRow extracts groupId when present', () {
    final event = InboundMessageEvent.fromRow({
      'id': 'group1::msg-1',
      'senderId': 'peer.onion',
      'receiverId': 'me.onion',
      'groupId': 'group1',
      'message': 'cipher',
      'type': 'group_text',
      'timestamp': 1000,
      'status': 'received',
    });

    expect(event.groupId, 'group1');
  });
}
