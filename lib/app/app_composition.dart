import 'package:prysm/crypto/peer_proof.dart';
import 'package:prysm/server/PrysmServer.dart';
import 'package:prysm/services/block_service.dart';
import 'package:prysm/services/call/call_manager.dart';
import 'package:prysm/services/file_transfer_handler.dart';
import 'package:prysm/services/message_search_backfill_service.dart';
import 'package:prysm/services/read_receipt_service.dart';
import 'package:prysm/services/sync_coordinator.dart';
import 'package:prysm/services/wake_hint_service.dart';
import 'package:prysm/transport/transport_provider.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/local_onion_address.dart';
import 'package:prysm/util/tor_runtime_gate.dart';
import 'package:prysm/util/tor_service.dart';

/// Composition root: every singleton `.configure`/wiring call that used to
/// be scattered across `main.dart`'s `_runMainApp`, `TorConnectionController`
/// and `_HomeScreenState` (Fase 5B). Behavior and call ORDER are ported
/// verbatim — only the call sites moved, each into the exact same position
/// in its caller. `main.dart`'s composition root (`_MyAppState`) creates the
/// shared `TorConnectionController`; this module is what that controller and
/// `AppBootstrap` call into to wire the singletons.
class AppComposition {
  const AppComposition._();

  /// Lets the rest of the app read the local onion address without
  /// importing `PrysmServer` directly.
  static void configureLocalOnionAddressProvider() {
    LocalOnionAddress.provider = () => PrysmServer.instance?.localOnionAddress;
  }

  /// Wires the singletons that come alive once Tor reports a connected
  /// result: outbound transport target, `CallManager`, and the
  /// `BlockService` <-> `CallManager` cycle break (Fase 3.3). Order matters
  /// — `CallManager.configure` must run before `CallManager.instance.start`.
  static void wireTorConnected({
    required TorManager torManager,
    required KeyManager keyManager,
  }) {
    TransportProvider.configure(torManager);
    // The outbound transport layer has no path to a KeyManager, so the
    // signing identity for transport-level proofs (sync hints, WS hello) is
    // injected here, where both are available. keyManager.identity throws
    // while locked — return null instead so transport code skips signing
    // rather than crashing.
    PeerProof.localIdentity = () {
      if (!keyManager.isUnlocked) return null;
      try {
        return keyManager.identity;
      } catch (_) {
        return null;
      }
    };
    CallManager.configure(keyManager: keyManager);
    CallManager.instance.start();
    BlockService.instance.onPeerBlocked = (peerOnion) =>
        CallManager.endCallWithPeer(peerOnion, reason: 'declined');
  }

  /// Creates the per-session [SyncCoordinator]. Kept here (rather than as a
  /// bare constructor call at the use site) so it sits next to the rest of
  /// the composition-root wiring it feeds into via [wireOnlineServices].
  static SyncCoordinator createSyncCoordinator({
    required String userId,
    required KeyManager keyManager,
    required TorManager torManager,
    required bool Function() isTorStopped,
  }) {
    return SyncCoordinator(
      userId: userId,
      keyManager: keyManager,
      torManager: torManager,
      isTorStopped: isTorStopped,
    );
  }

  /// Wires the online-mode singletons once Tor and a [SyncCoordinator] are
  /// available: outbound transport's peer-connected callback + websocket
  /// start, file transfers, the Tor runtime gate, sync start, wake hints,
  /// and read-receipt flush. Same order as the original
  /// `_HomeScreenState._wireOnlineServices`.
  static void wireOnlineServices({
    required TorManager torManager,
    required SyncCoordinator syncCoordinator,
    required String onionAddress,
    required bool Function() isTorStopped,
  }) {
    TransportProvider.configure(
      torManager,
      onPeerConnected: (peerId) => syncCoordinator.flushPendingForPeer(peerId),
    );
    TransportProvider.instance.startWebSocketConnections();
    FileTransferHandler.instance.start();
    TorRuntimeGate.isTorStopped = isTorStopped;
    syncCoordinator.start();
    WakeHintService.instance.configure(
      userId: onionAddress,
      onFlushPeer: (peerId) => syncCoordinator.flushPendingForPeer(peerId),
    );
    ReadReceiptService.configure(
      flushPendingForPeer: (peerId) => syncCoordinator.flushPendingForPeer(peerId),
    );
  }

  /// Wires only the Tor runtime gate — used when online-services wiring is
  /// skipped (offline mode, non-decoy session) but health monitoring still
  /// needs to know whether Tor was intentionally stopped.
  static void wireTorRuntimeGate(bool Function() isTorStopped) {
    TorRuntimeGate.isTorStopped = isTorStopped;
  }

  /// Starts background indexing of historical messages for FTS search.
  static void startSearchBackfill({
    required KeyManager keyManager,
    required String userId,
  }) {
    MessageSearchBackfillService(
      keyManager: keyManager,
      userId: userId,
    ).startIfNeeded();
  }
}
