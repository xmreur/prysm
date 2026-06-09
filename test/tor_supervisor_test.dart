import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/util/tor_health_status.dart';
import 'package:prysm/util/tor_service.dart';
import 'package:prysm/util/tor_supervisor.dart';

class _FakeTorManager extends TorManager {
  _FakeTorManager({required this.status})
      : super(torPath: '/bin/false', dataDir: '/tmp/tor-fake');

  TorHealthStatus status;

  @override
  Future<TorHealthStatus> getHealthStatus() async => status;
}

void main() {
  group('TorSupervisor.shouldAllowAutoRestart', () {
    late TorSupervisor supervisor;

    setUp(() {
      supervisor = TorSupervisor(
        torManager: TorManager(torPath: '/bin/false', dataDir: '/tmp/tor-test'),
        isTorStopped: () => false,
        isRestartInProgress: () => false,
        performRestart: ({bool userInitiated = false}) async {},
        enabled: false,
      );
    });

    test('blocks when max restarts in window reached', () {
      final now = DateTime(2026, 1, 1, 12, 0);
      final recent = [
        now.subtract(const Duration(minutes: 5)),
        now.subtract(const Duration(minutes: 10)),
        now.subtract(const Duration(minutes: 20)),
      ];

      expect(
        supervisor.shouldAllowAutoRestart(
          now: now,
          recentRestarts: recent,
          lastRestart: now.subtract(const Duration(minutes: 2)),
        ),
        isFalse,
      );
    });

    test('blocks when min interval not elapsed', () {
      final now = DateTime(2026, 1, 1, 12, 0);

      expect(
        supervisor.shouldAllowAutoRestart(
          now: now,
          recentRestarts: const [],
          lastRestart: now.subtract(const Duration(seconds: 30)),
        ),
        isFalse,
      );
    });

    test('allows when under cap and interval elapsed', () {
      final now = DateTime(2026, 1, 1, 12, 0);

      expect(
        supervisor.shouldAllowAutoRestart(
          now: now,
          recentRestarts: [now.subtract(const Duration(minutes: 10))],
          lastRestart: now.subtract(const Duration(minutes: 2)),
        ),
        isTrue,
      );
    });
  });

  group('TorSupervisor.evaluateHealth bootstrap grace', () {
    test('does not count bootstrap failures within 60s of start', () async {
      final manager = _FakeTorManager(
        status: const TorHealthStatus(
          ok: false,
          reason: 'Tor bootstrap incomplete (42%)',
        ),
      );
      manager.lastStartAt = DateTime.now().subtract(const Duration(seconds: 10));

      final supervisor = TorSupervisor(
        torManager: manager,
        isTorStopped: () => false,
        isRestartInProgress: () => false,
        performRestart: ({bool userInitiated = false}) async {},
        enabled: true,
      );

      final eval = await supervisor.evaluateHealth();
      expect(eval.connection, TorConnectionEvaluation.disconnected);
      expect(supervisor.autoRestartCount, 0);

      final eval2 = await supervisor.evaluateHealth();
      expect(eval2.connection, TorConnectionEvaluation.disconnected);
      expect(supervisor.autoRestartCount, 0);
    });
  });
}
