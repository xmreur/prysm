import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/services/ws_connection_manager.dart';
import 'package:prysm/transport/ws_peer_link.dart';
import 'package:prysm/util/peer_ws_connection_notifier.dart';
import 'package:prysm/util/tor_service.dart';

void main() {
  test('notifier fires on link register and remove', () async {
    final manager = WsConnectionManager(
      TorManager(torPath: '/bin/false', dataDir: '/tmp/ws-notifier-test'),
    );
    final events = <PeerWsConnectionEvent>[];
    final sub = PeerWsConnectionNotifier.instance.onChanged.listen(events.add);

    manager.registerLinkForTest('peer.onion', _FakeWsPeerLink('peer.onion'));
    await Future<void>.delayed(Duration.zero);
    expect(events, hasLength(1));
    expect(events.last.peerOnion, 'peer.onion');
    expect(events.last.connected, isTrue);

    manager.unregisterLink('peer.onion');
    await Future<void>.delayed(Duration.zero);
    expect(events, hasLength(2));
    expect(events.last.peerOnion, 'peer.onion');
    expect(events.last.connected, isFalse);

    await sub.cancel();
    manager.dispose();
  });
}

class _FakeWsPeerLink implements WsPeerLink {
  _FakeWsPeerLink(this.peerOnion);

  @override
  final String peerOnion;

  @override
  bool isConnected = true;

  @override
  Stream<Map<String, dynamic>> get onPushFrames =>
      const Stream<Map<String, dynamic>>.empty();

  @override
  Stream<List<int>> get onBinaryFrames => const Stream<List<int>>.empty();

  @override
  Future<void> close() async {
    isConnected = false;
  }

  @override
  Future<Map<String, dynamic>> request(
    String op, {
    Map<String, dynamic>? payload,
    Duration timeout = const Duration(seconds: 30),
  }) async =>
      <String, dynamic>{};

  @override
  Future<void> send(String op, {Map<String, dynamic>? payload}) async {}

  @override
  Future<void> sendBytes(List<int> bytes) async {}

  @override
  Future<void> sendPing() async {}
}
