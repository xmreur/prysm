import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/transport/peer_transport_registry.dart';

void main() {
  setUp(() {
    PeerTransportRegistry.instance.resetForTest();
  });

  test('marks peers as websocket capable', () {
    final registry = PeerTransportRegistry.instance;
    expect(registry.modeFor('peer.onion'), PeerTransportMode.unknown);

    registry.markWebSocket('peer.onion');
    expect(registry.supportsWebSocket('peer.onion'), isTrue);
    expect(registry.isHttpOnly('peer.onion'), isFalse);
  });

  test('clearPeer resets mode to unknown', () {
    final registry = PeerTransportRegistry.instance;
    registry.markWebSocket('peer.onion');
    registry.clearPeer('peer.onion');
    expect(registry.modeFor('peer.onion'), PeerTransportMode.unknown);
  });

  test('isHttpOnly is always false', () {
    final registry = PeerTransportRegistry.instance;
    registry.markHttpOnly('peer.onion');
    expect(registry.isHttpOnly('peer.onion'), isFalse);
  });
}
