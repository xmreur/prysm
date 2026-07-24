// Tests for TorConnectionController (Fase 5A extraction of the Tor
// connection state machine that used to live across `_MyAppState` and
// `_HomeScreenState` in main.dart). Uses a hand-written fake TorManager
// (same style as tor_supervisor_test.dart) plus ctor-injected seams for
// the module-level bootstrap helpers (torManagerFactory/torInitializer/
// hasInternet), so no real network/process/plugin channel is touched.
import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/app/tor_connection_controller.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/tor_connection_notifier.dart';
import 'package:prysm/util/tor_health_status.dart';
import 'package:prysm/util/tor_lifecycle_state.dart';
import 'package:prysm/util/tor_service.dart';

class _FakeTorManager extends TorManager {
  _FakeTorManager({
    this.onionAddress = 'fake.onion',
    this.cachedOnionAddress,
    TorHealthStatus health = TorHealthStatus.healthy,
  }) : _health = health,
       super(torPath: '/bin/false', dataDir: '/tmp/tor-connection-ctrl-test');

  String? onionAddress;
  String? cachedOnionAddress;
  TorHealthStatus _health;
  bool startTorThrows = false;
  bool startTorFailsOnce = false;
  var startCallCount = 0;
  var stopCallCount = 0;

  void setHealth(TorHealthStatus health) => _health = health;

  @override
  Future<void> startTor() async {
    startCallCount++;
    if (startTorThrows || (startTorFailsOnce && startCallCount == 1)) {
      throw Exception('start failed');
    }
  }

  @override
  Future<void> stopTor() async {
    stopCallCount++;
  }

  @override
  Future<String?> getOnionAddress() async => onionAddress;

  @override
  Future<String?> getCachedOnionAddress() async => cachedOnionAddress;

  @override
  Future<TorHealthStatus> getHealthStatus() async => _health;

  @override
  Future<bool> isHealthy() async => _health.ok;

  @override
  Future<bool> refreshCircuit() async => true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // checkHealth() bails out early while TorLifecycleNotifier reports
  // "blocked" (its default state until something marks Tor ready) — mirror
  // what startMonitoring() does in real usage before health checks run.
  setUp(() {
    TorLifecycleNotifier.instance.update(TorLifecycleState.ready);
  });
  group('connect', () {
    test('succeeds: applies result, marks ready, calls onConnected', () async {
      final fakeManager = _FakeTorManager(onionAddress: 'good.onion');
      TorInitResult? connectedResult;
      final controller = TorConnectionController(
        keyManager: KeyManager(),
        hasInternet: () async => true,
        torInitializer: () async =>
            TorInitResult(torManager: fakeManager, onionAddress: 'good.onion'),
        onConnected: (result) => connectedResult = result,
      );
      addTearDown(controller.dispose);

      await controller.connect();

      expect(controller.ready, isTrue);
      expect(controller.failed, isFalse);
      expect(controller.connecting, isFalse);
      expect(controller.offline, isFalse);
      expect(controller.onionAddress, 'good.onion');
      expect(controller.status, 'Connected');
      expect(connectedResult?.torManager, same(fakeManager));
    });

    test('no internet: fails fast without initializing Tor', () async {
      var initCalled = false;
      final controller = TorConnectionController(
        keyManager: KeyManager(),
        hasInternet: () async => false,
        torInitializer: () async {
          initCalled = true;
          throw StateError('should not be called');
        },
      );
      addTearDown(controller.dispose);

      await controller.connect();

      expect(initCalled, isFalse);
      expect(controller.failed, isTrue);
      expect(controller.status, 'No internet connection detected.');
    });

    test('initializer throws: falls back to offline mode', () async {
      final offlineManager = _FakeTorManager(
        cachedOnionAddress: 'cached.onion',
      );
      final controller = TorConnectionController(
        keyManager: KeyManager(),
        hasInternet: () async => true,
        torInitializer: () async => throw Exception('boom'),
        torManagerFactory: ({allowDownload = true}) async => offlineManager,
      );
      addTearDown(controller.dispose);

      await controller.connect();

      expect(controller.failed, isTrue);
      expect(controller.offline, isTrue);
      expect(controller.connecting, isFalse);
      expect(controller.onionAddress, 'cached.onion');
    });

    test('retry resets failed/offline flags then reconnects', () async {
      final fakeManager = _FakeTorManager();
      var attempts = 0;
      final controller = TorConnectionController(
        keyManager: KeyManager(),
        hasInternet: () async => true,
        torInitializer: () async {
          attempts++;
          if (attempts == 1) throw Exception('first attempt fails');
          return TorInitResult(
            torManager: fakeManager,
            onionAddress: 'ok.onion',
          );
        },
        torManagerFactory: ({allowDownload = true}) async => fakeManager,
      );
      addTearDown(controller.dispose);

      await controller.connect();
      expect(controller.failed, isTrue);

      await controller.retry();

      expect(controller.failed, isFalse);
      expect(controller.ready, isTrue);
      expect(attempts, 2);
    });
  });

  group('enterOfflineMode', () {
    test('with a cached onion address', () async {
      final controller = TorConnectionController(
        keyManager: KeyManager(),
        torManagerFactory: ({allowDownload = true}) async =>
            _FakeTorManager(cachedOnionAddress: 'stale.onion'),
      );
      addTearDown(controller.dispose);

      await controller.enterOfflineMode();

      expect(controller.offline, isTrue);
      expect(controller.ready, isFalse);
      expect(controller.onionAddress, 'stale.onion');
      expect(controller.status, 'Offline');
    });

    test('without a cached onion address prompts to connect', () async {
      final controller = TorConnectionController(
        keyManager: KeyManager(),
        torManagerFactory: ({allowDownload = true}) async =>
            _FakeTorManager(cachedOnionAddress: null),
      );
      addTearDown(controller.dispose);

      await controller.enterOfflineMode();

      expect(
        controller.status,
        'Offline — connect to Tor to get your Prysm ID',
      );
    });
  });

  group('checkHealth (no supervisor)', () {
    test(
      'transitions from disconnected to connected and notifies listeners',
      () async {
        final fakeManager = _FakeTorManager(health: TorHealthStatus.healthy);
        final controller = TorConnectionController(keyManager: KeyManager())
          ..torManager = fakeManager
          ..connectionState = TorConnectionState.disconnected;
        addTearDown(controller.dispose);

        var notified = 0;
        controller.addListener(() => notified++);

        await controller.checkHealth();

        expect(controller.connectionState, TorConnectionState.connected);
        expect(notified, greaterThan(0));
      },
    );

    test('unhealthy TorManager reports disconnected', () async {
      final fakeManager = _FakeTorManager(
        health: const TorHealthStatus(ok: false, reason: 'down'),
      );
      final controller = TorConnectionController(keyManager: KeyManager())
        ..torManager = fakeManager
        ..connectionState = TorConnectionState.connected;
      addTearDown(controller.dispose);

      await controller.checkHealth();

      expect(controller.connectionState, TorConnectionState.disconnected);
    });

    test('torStopped short-circuits to disconnected without polling', () async {
      final fakeManager = _FakeTorManager(health: TorHealthStatus.healthy);
      final controller = TorConnectionController(keyManager: KeyManager())
        ..torManager = fakeManager
        ..torStopped = true
        ..connectionState = TorConnectionState.connected;
      addTearDown(controller.dispose);

      await controller.checkHealth();

      expect(controller.connectionState, TorConnectionState.disconnected);
    });

    test('reconnecting after a disconnect invokes onReconnected', () async {
      final fakeManager = _FakeTorManager(
        health: const TorHealthStatus(ok: false),
      );
      final controller = TorConnectionController(keyManager: KeyManager())
        ..torManager = fakeManager
        ..connectionState = TorConnectionState.disconnected;
      var reconnected = 0;
      controller.onReconnected = () async {
        reconnected++;
      };
      addTearDown(controller.dispose);

      // Still disconnected: no reconnect callback.
      await controller.checkHealth();
      expect(reconnected, 0);

      fakeManager.setHealth(TorHealthStatus.healthy);
      await controller.checkHealth();
      // unawaited inside the controller — flush the microtask queue.
      await Future<void>.delayed(Duration.zero);

      expect(controller.connectionState, TorConnectionState.connected);
      expect(reconnected, 1);
    });
  });

  group('performRestart', () {
    test(
      'success: stops/starts Tor, ends connected, notifies success',
      () async {
        final fakeManager = _FakeTorManager(onionAddress: 'restarted.onion');
        final controller = TorConnectionController(keyManager: KeyManager())
          ..torManager = fakeManager;
        var succeeded = false;
        controller.onRestartSucceeded = () => succeeded = true;
        addTearDown(controller.dispose);

        await controller.performRestart(userInitiated: true);

        expect(fakeManager.stopCallCount, 1);
        expect(fakeManager.startCallCount, 1);
        expect(controller.torStopped, isFalse);
        expect(controller.restartInProgress, isFalse);
        expect(controller.connectionState, TorConnectionState.connected);
        expect(succeeded, isTrue);
      },
    );

    test('failure: reports disconnected and invokes onRestartFailed', () async {
      final fakeManager = _FakeTorManager()..startTorThrows = true;
      final controller = TorConnectionController(keyManager: KeyManager())
        ..torManager = fakeManager;
      Object? failure;
      controller.onRestartFailed = (e) => failure = e;
      addTearDown(controller.dispose);

      await controller.performRestart(userInitiated: true);

      expect(controller.torStopped, isTrue);
      expect(controller.restartInProgress, isFalse);
      expect(controller.connectionState, TorConnectionState.disconnected);
      expect(failure, isNotNull);
    });

    test(
      'a second concurrent call is a no-op while one is in progress',
      () async {
        final fakeManager = _FakeTorManager();
        final controller = TorConnectionController(keyManager: KeyManager())
          ..torManager = fakeManager;
        addTearDown(controller.dispose);

        final first = controller.performRestart();
        final second = controller.performRestart();
        await Future.wait([first, second]);

        // Only the first call actually talked to the TorManager.
        expect(fakeManager.startCallCount, 1);
      },
    );
  });

  group('startMonitoring', () {
    test(
      'creates a supervisor, marks running, and starts the health timer',
      () async {
        final fakeManager = _FakeTorManager(health: TorHealthStatus.healthy);
        final controller = TorConnectionController(keyManager: KeyManager())
          ..torManager = fakeManager;
        addTearDown(controller.dispose);

        controller.startMonitoring(decoyMode: false);
        // startMonitoring runs an initial checkHealth() synchronously up to
        // its first await; flush microtasks so it settles.
        await Future<void>.delayed(Duration.zero);

        expect(controller.torStopped, isFalse);
        expect(controller.supervisor, isNotNull);
      },
    );
  });

  group('shutdown', () {
    test('stops Tor exactly once even if called twice', () async {
      final fakeManager = _FakeTorManager();
      final controller = TorConnectionController(keyManager: KeyManager())
        ..torManager = fakeManager;
      addTearDown(controller.dispose);

      await controller.shutdown();
      await controller.shutdown();

      expect(controller.torStopped, isTrue);
      expect(fakeManager.stopCallCount, 1);
    });
  });

  group('clearReconnectCallbacks', () {
    // Regression test for the Fase 5A review finding: dispose() only did
    // removeListener + stopMonitoring, leaving onReconnected/
    // onRestartSucceeded/onRestartFailed pointed at closures owned by a
    // (possibly already-disposed) _HomeScreenState. A health-monitor tick
    // or in-flight restart that resolves afterwards must not still be able
    // to reach those closures.
    test('detaches all three callbacks so stale closures never fire', () async {
      final fakeManager = _FakeTorManager(
        health: const TorHealthStatus(ok: false),
      );
      final controller = TorConnectionController(keyManager: KeyManager())
        ..torManager = fakeManager
        ..connectionState = TorConnectionState.disconnected;
      addTearDown(controller.dispose);

      var reconnected = 0;
      var restartSucceeded = 0;
      var restartFailed = 0;
      controller.onReconnected = () async => reconnected++;
      controller.onRestartSucceeded = () => restartSucceeded++;
      controller.onRestartFailed = (_) => restartFailed++;

      controller.clearReconnectCallbacks();

      expect(controller.onReconnected, isNull);
      expect(controller.onRestartSucceeded, isNull);
      expect(controller.onRestartFailed, isNull);

      // A reconnect that would have fired onReconnected pre-detach must
      // now be a silent no-op.
      fakeManager.setHealth(TorHealthStatus.healthy);
      await controller.checkHealth();
      await Future<void>.delayed(Duration.zero);
      expect(controller.connectionState, TorConnectionState.connected);
      expect(reconnected, 0);

      // A user-initiated restart that would have fired onRestartSucceeded
      // pre-detach must also be a silent no-op.
      await controller.performRestart(userInitiated: true);
      expect(restartSucceeded, 0);
      expect(restartFailed, 0);
    });
  });
}
