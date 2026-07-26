// Fase 5B: characterizes the composition-root wiring in
// lib/app/app_composition.dart, extracted from main.dart's _runMainApp,
// TorConnectionController._applyConnectedResult, and
// _HomeScreenState._wireOnlineServices. Covers the pieces that are safe to
// exercise without touching real network/Tor/call singletons (CallManager,
// TransportProvider, ReadReceiptService wiring is verified indirectly via
// the full suite + `flutter build linux --debug`, matching the fact that
// no pre-existing test exercised that combined path before the extraction
// either).
import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/app/app_composition.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/local_onion_address.dart';
import 'package:prysm/util/tor_runtime_gate.dart';
import 'package:prysm/util/tor_service.dart';

void main() {
  tearDown(() {
    LocalOnionAddress.provider = null;
    TorRuntimeGate.resetForTest();
  });

  group('configureLocalOnionAddressProvider', () {
    test('wires a provider that reads PrysmServer.instance safely', () {
      expect(LocalOnionAddress.provider, isNull);

      AppComposition.configureLocalOnionAddressProvider();

      expect(LocalOnionAddress.provider, isNotNull);
      // No PrysmServer has been constructed in this test: the provider
      // must not throw, and must report no address yet.
      expect(LocalOnionAddress.value, isNull);
    });
  });

  group('createSyncCoordinator', () {
    test('forwards every argument to SyncCoordinator unchanged', () {
      final keyManager = KeyManager();
      final torManager = TorManager(
        torPath: '/bin/false',
        dataDir: '/tmp/app-composition-test',
      );
      bool isTorStopped() => true;

      final coordinator = AppComposition.createSyncCoordinator(
        userId: 'me.onion',
        keyManager: keyManager,
        torManager: torManager,
        isTorStopped: isTorStopped,
      );

      expect(coordinator.userId, 'me.onion');
      expect(coordinator.keyManager, same(keyManager));
      expect(coordinator.torManager, same(torManager));
      expect(coordinator.isTorStopped, same(isTorStopped));
    });
  });

  group('wireTorRuntimeGate', () {
    test('sets TorRuntimeGate.isTorStopped', () {
      expect(TorRuntimeGate.blocked, isFalse);

      AppComposition.wireTorRuntimeGate(() => true);

      expect(TorRuntimeGate.isTorStopped, isNotNull);
      expect(TorRuntimeGate.blocked, isTrue);
    });
  });
}
