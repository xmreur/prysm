import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/services/ws_connection_manager.dart';
import 'package:prysm/transport/peer_transport_registry.dart';
import 'package:prysm/util/tor_runtime_gate.dart';
import 'package:prysm/util/tor_service.dart';

void main() {
  setUp(() {
    PeerTransportRegistry.instance.resetForTest();
    TorRuntimeGate.isTorStopped = null;
  });

  tearDown(() {
    TorRuntimeGate.isTorStopped = null;
  });

  test('interactive connect budget is platform aware', () {
    expect(
      WsConnectionManager.interactiveConnectBudget.inSeconds,
      greaterThanOrEqualTo(12),
    );
  });

  test('ensureConnected rejects httpOnly peers', () async {
    final manager = WsConnectionManager(
      TorManager(torPath: '/bin/false', dataDir: '/tmp/ws-manager-test'),
    );
    PeerTransportRegistry.instance.markHttpOnly('blocked.onion');

    await expectLater(
      manager.ensureConnected('blocked.onion'),
      throwsA(isA<StateError>()),
    );

    manager.dispose();
  });

  test('ensureConnected rejects when Tor is stopped', () async {
    TorRuntimeGate.isTorStopped = () => true;
    final manager = WsConnectionManager(
      TorManager(torPath: '/bin/false', dataDir: '/tmp/ws-manager-test-2'),
    );

    await expectLater(
      manager.ensureConnected('peer.onion'),
      throwsA(isA<StateError>()),
    );

    manager.dispose();
  });
}
