import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/transport/peer_transport_registry.dart';

void main() {
  setUp(() {
    PeerTransportRegistry.instance.resetForTest();
  });

  test('marks peers as HTTP-only and websocket capable', () {
    final registry = PeerTransportRegistry.instance;
    expect(registry.modeFor('peer.onion'), PeerTransportMode.unknown);

    registry.markHttpOnly('peer.onion');
    expect(registry.isHttpOnly('peer.onion'), isTrue);

    registry.markWebSocket('other.onion');
    expect(registry.supportsWebSocket('other.onion'), isTrue);
    expect(registry.isHttpOnly('other.onion'), isFalse);
  });

  test('clearPeer resets mode to unknown', () {
    final registry = PeerTransportRegistry.instance;
    registry.markHttpOnly('peer.onion');
    registry.clearPeer('peer.onion');
    expect(registry.modeFor('peer.onion'), PeerTransportMode.unknown);
  });

  test('httpOnly expires after TTL', () {
    final registry = PeerTransportRegistry.instance;
    final expiredAt = DateTime.now().subtract(
      PeerTransportRegistry.httpOnlyTtl + const Duration(minutes: 1),
    );
    registry.setHttpOnlyAtForTest('old.onion', expiredAt);

    expect(registry.isHttpOnly('old.onion'), isFalse);
    expect(registry.modeFor('old.onion'), PeerTransportMode.unknown);
  });

  test('clearHttpOnlyAll removes all httpOnly peers', () {
    final registry = PeerTransportRegistry.instance;
    registry.markHttpOnly('a.onion');
    registry.markHttpOnly('b.onion');
    registry.markWebSocket('c.onion');

    registry.clearHttpOnlyAll();

    expect(registry.isHttpOnly('a.onion'), isFalse);
    expect(registry.isHttpOnly('b.onion'), isFalse);
    expect(registry.supportsWebSocket('c.onion'), isTrue);
  });
}
