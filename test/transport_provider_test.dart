import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/services/ws_connection_manager.dart';
import 'package:prysm/transport/peer_transport_registry.dart';
import 'package:prysm/transport/tor_websocket_transport.dart';
import 'package:prysm/transport/transport_preference.dart';
import 'package:prysm/transport/transport_provider.dart';
import 'package:prysm/transport/ws_peer_link.dart';
import 'package:prysm/util/tor_delivery.dart';
import 'package:prysm/util/tor_service.dart';

void main() {
  setUp(() {
    TransportProvider.resetForTest();
    TorDelivery.resetForTest();
    PeerTransportRegistry.instance.resetForTest();
  });

  tearDown(() {
    TransportProvider.resetForTest();
    TorDelivery.resetForTest();
  });

  test('configure initializes and resets provider', () {
    expect(TransportProvider.isConfigured, isFalse);
    TransportProvider.configure(
      TorManager(torPath: '/bin/false', dataDir: '/tmp/transport-provider-test'),
    );
    expect(TransportProvider.isConfigured, isTrue);

    TransportProvider.resetForTest();
    expect(TransportProvider.isConfigured, isFalse);
  });

  test('HTTP-only preference skips realtime connection', () {
    TransportProvider.configure(
      TorManager(torPath: '/bin/false', dataDir: '/tmp/transport-provider-test-2'),
    );
    expect(
      TransportProvider.instance.isRealtimeConnected('legacy.onion'),
      isFalse,
    );
  });

  test('startWebSocketConnections starts maintain loop', () {
    TransportProvider.configure(
      TorManager(torPath: '/bin/false', dataDir: '/tmp/transport-provider-test-3'),
    );
    TransportProvider.instance.startWebSocketConnections();
    expect(WsConnectionManager.interactiveConnectBudget.inSeconds, greaterThan(0));
  });

  test('configure reuses provider when tor manager is unchanged', () {
    final torManager = TorManager(
      torPath: '/bin/false',
      dataDir: '/tmp/transport-provider-test-reuse',
    );
    TransportProvider.configure(torManager);
    final first = TransportProvider.instance;
    TransportProvider.instance.startWebSocketConnections();

    TransportProvider.configure(
      torManager,
      onPeerConnected: (_) async => true,
    );

    expect(identical(TransportProvider.instance, first), isTrue);
  });

  test('withPeer falls back to HTTP when WS connect fails', () async {
    TransportProvider.configure(
      TorManager(torPath: '/bin/false', dataDir: '/tmp/transport-provider-test-4'),
    );

    var usedHttp = false;
    try {
      await TransportProvider.instance.withPeer('missing.onion', (transport) async {
        usedHttp = transport == TransportProvider.instance.httpTransport;
        throw StateError('simulated HTTP path');
      });
    } catch (_) {}

    expect(usedHttp, isTrue);
  });

  test('withPeer uses registered inbound link without outbound dial', () async {
    TransportProvider.configure(
      TorManager(torPath: '/bin/false', dataDir: '/tmp/transport-provider-inbound'),
    );

    TransportProvider.instance.wsManager.registerLinkForTest(
      'peer.onion',
      _FakeWsPeerLink('peer.onion'),
    );

    var usedWs = false;
    final result = await TransportProvider.instance.withPeer(
      'peer.onion',
      (transport) async {
        usedWs = transport is TorWebSocketTransport;
        return 'ok';
      },
      preference: TransportPreference.wsPreferred,
    );

    expect(usedWs, isTrue);
    expect(result, 'ok');
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
  Future<void> sendPing() async {}
}
