import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/services/ws_connection_manager.dart';
import 'package:prysm/transport/peer_transport_registry.dart';
import 'package:prysm/transport/transport_preference.dart';
import 'package:prysm/transport/transport_provider.dart';
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

  test('HTTP-only peers skip realtime connection checks', () {
    TransportProvider.configure(
      TorManager(torPath: '/bin/false', dataDir: '/tmp/transport-provider-test-2'),
    );
    PeerTransportRegistry.instance.markHttpOnly('legacy.onion');
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
    expect(
      PeerTransportRegistry.instance.isHttpOnly('missing.onion'),
      isFalse,
    );
  });

  test('wsPreferred uses HTTP immediately when WS is not connected', () async {
    TransportProvider.configure(
      TorManager(torPath: '/bin/false', dataDir: '/tmp/transport-provider-test-6'),
    );

    var usedHttp = false;
    final sw = Stopwatch()..start();
    await TransportProvider.instance.withPeer(
      'peer.onion',
      (transport) async {
        usedHttp = transport == TransportProvider.instance.httpTransport;
        return 'ok';
      },
      preference: TransportPreference.wsPreferred,
    );
    sw.stop();

    expect(usedHttp, isTrue);
    expect(sw.elapsed.inSeconds, lessThan(3));
  });
}
