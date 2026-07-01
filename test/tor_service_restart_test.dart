import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/util/tor_health_status.dart';
import 'package:prysm/util/tor_lifecycle_state.dart';
import 'package:prysm/util/tor_runtime_gate.dart';
import 'package:prysm/util/tor_service.dart';

void main() {
  group('parseBootstrapProgress', () {
    test('reads PROGRESS from bootstrap-phase line', () {
      expect(
        parseBootstrapProgress([
          '250-status/bootstrap-phase=NOTICE PROGRESS=100 TAG=done',
        ]),
        100,
      );
      expect(
        parseBootstrapProgress([
          '250-status/bootstrap-phase=NOTICE PROGRESS=42 TAG=loading',
        ]),
        42,
      );
    });

    test('returns null when line missing', () {
      expect(parseBootstrapProgress(const ['250 OK']), isNull);
    });
  });

  group('isNetworkLive', () {
    test('treats netdown as unhealthy', () {
      expect(
        isNetworkLive(['250-network-liveness=netdown']),
        isFalse,
      );
    });

    test('treats missing line as live', () {
      expect(isNetworkLive(const []), isTrue);
    });
  });

  group('TorManager.shouldHandleProcessExit', () {
    test('ignores stale generation exits', () {
      expect(
        TorManager.shouldHandleProcessExit(1, 2, null, null),
        isFalse,
      );
    });
  });

  group('TorManager.shouldClearControlSessionOnSocketDone', () {
    test('clears only when closed generation matches current', () {
      expect(
        TorManager.shouldClearControlSessionOnSocketDone(2, 2),
        isTrue,
      );
      expect(
        TorManager.shouldClearControlSessionOnSocketDone(2, 3),
        isFalse,
      );
    });

    test('stale socket done after reconnect must not clear new session', () {
      const oldSocketGeneration = 1;
      const currentGenerationAfterReconnect = 2;

      expect(
        TorManager.shouldClearControlSessionOnSocketDone(
          oldSocketGeneration,
          currentGenerationAfterReconnect,
        ),
        isFalse,
      );
    });
  });

  group('TorRuntimeGate with lifecycle', () {
    tearDown(TorRuntimeGate.resetForTest);

    test('blocks while lifecycle is not ready', () {
      TorRuntimeGate.isTorStopped = () => false;
      TorLifecycleNotifier.instance.update(TorLifecycleState.restarting);
      expect(TorRuntimeGate.blocked, isTrue);
    });

    test('unblocks when lifecycle is ready and Tor is running', () {
      TorRuntimeGate.isTorStopped = () => false;
      TorLifecycleNotifier.instance.update(TorLifecycleState.ready);
      expect(TorRuntimeGate.blocked, isFalse);
    });
  });
}
