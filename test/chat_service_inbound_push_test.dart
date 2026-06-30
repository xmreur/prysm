import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/crypto/identity.dart';
import 'package:prysm/services/chat_service.dart';
import 'package:prysm/util/inbound_message_notifier.dart';
import 'package:prysm/util/key_manager.dart';

void main() {
  late KeyManager keyManager;
  late ChatService service;
  late IdentityKeyPair peerIdentity;

  setUp(() async {
    InboundMessageNotifier.instance.resetForTest();

    final local = await IdentityKeyPair.generate();
    peerIdentity = await IdentityKeyPair.generate();
    keyManager = KeyManager.fromIdentity(local);

    service = ChatService(
      userId: 'me.onion',
      peerId: 'peer.onion',
      keyManager: keyManager,
    );
    service.peerIdentity = IdentityPublicKeys(
      signPublic: await peerIdentity.signPublicKey,
      agreePublic: await peerIdentity.agreePublicKey,
      fingerprint: 'test',
    );
  });

  tearDown(() {
    service.dispose();
    InboundMessageNotifier.instance.resetForTest();
  });

  Map<String, dynamic> directRow({
    required String storageId,
    required String wireId,
    int timestamp = 1000,
  }) {
    return {
      'id': storageId,
      'senderId': 'peer.onion',
      'receiverId': 'me.onion',
      'message': 'cipher',
      'type': 'text',
      'timestamp': timestamp,
      'status': 'received',
    };
  }

  test('push delivers matching direct message immediately', () async {
    final delivered = <List<Map<String, dynamic>>>[];
    service.onNewMessages.listen(delivered.add);
    service.startInboundPushListener();

    final row = directRow(storageId: 'peer.onion::msg-1', wireId: 'msg-1');
    InboundMessageNotifier.instance.notify(InboundMessageEvent.fromRow(row));

    await Future<void>.delayed(Duration.zero);
    expect(delivered, hasLength(1));
    expect(delivered.first.single['id'], 'peer.onion::msg-1');
  });

  test('push ignores messages for other peers', () async {
    final delivered = <List<Map<String, dynamic>>>[];
    service.onNewMessages.listen(delivered.add);
    service.startInboundPushListener();

    InboundMessageNotifier.instance.notify(
      InboundMessageEvent.fromRow({
        'id': 'other.onion::msg-1',
        'senderId': 'other.onion',
        'receiverId': 'me.onion',
        'message': 'cipher',
        'type': 'text',
        'timestamp': 1000,
        'status': 'received',
      }),
    );

    await Future<void>.delayed(Duration.zero);
    expect(delivered, isEmpty);
  });

  test('duplicate push is deduped', () async {
    final delivered = <List<Map<String, dynamic>>>[];
    service.onNewMessages.listen(delivered.add);
    service.startInboundPushListener();

    final row = directRow(storageId: 'peer.onion::msg-1', wireId: 'msg-1');
    final event = InboundMessageEvent.fromRow(row);
    InboundMessageNotifier.instance.notify(event);
    InboundMessageNotifier.instance.notify(event);

    await Future<void>.delayed(Duration.zero);
    expect(delivered, hasLength(1));
  });

  test('push ignores group messages for direct chat service', () async {
    final delivered = <List<Map<String, dynamic>>>[];
    service.onNewMessages.listen(delivered.add);
    service.startInboundPushListener();

    InboundMessageNotifier.instance.notify(
      InboundMessageEvent.fromRow({
        'id': 'group1::msg-1',
        'senderId': 'peer.onion',
        'receiverId': 'me.onion',
        'groupId': 'group1',
        'message': 'cipher',
        'type': 'group_text',
        'timestamp': 1000,
        'status': 'received',
      }),
    );

    await Future<void>.delayed(Duration.zero);
    expect(delivered, isEmpty);
  });
}
