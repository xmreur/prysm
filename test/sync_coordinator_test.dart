import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/services/sync_coordinator.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/tor_service.dart';

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
  });

  test('flushAllPending is skipped when Tor is stopped', () async {
    final coordinator = SyncCoordinator(
      userId: 'me.onion',
      keyManager: KeyManager(),
      torManager: TorManager(torPath: '', dataDir: '', controlPassword: ''),
      isTorStopped: () => true,
    );

    final flushed = await coordinator.flushAllPending();
    expect(flushed, false);
    coordinator.dispose();
  });

  test('onTorReconnected returns false when Tor is stopped', () async {
    final coordinator = SyncCoordinator(
      userId: 'me.onion',
      keyManager: KeyManager(),
      torManager: TorManager(torPath: '', dataDir: '', controlPassword: ''),
      isTorStopped: () => true,
    );

    expect(await coordinator.onTorReconnected(), false);
    coordinator.dispose();
  });

  test('flushPendingForPeer is skipped when Tor is stopped', () async {
    final coordinator = SyncCoordinator(
      userId: 'me.onion',
      keyManager: KeyManager(),
      torManager: TorManager(torPath: '', dataDir: '', controlPassword: ''),
      isTorStopped: () => true,
    );

    expect(await coordinator.flushPendingForPeer('peer.onion'), false);
    coordinator.dispose();
  });
}
