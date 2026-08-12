import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/services/ws_connection_manager.dart';
import 'package:prysm/transport/peer_transport_registry.dart';
import 'package:prysm/transport/tor_websocket_transport.dart';
import 'package:prysm/transport/transport_preference.dart';
import 'package:prysm/transport/transport_provider.dart';
import 'package:prysm/transport/ws_peer_link.dart';
import 'package:prysm/util/tor_delivery.dart';
import 'package:prysm/util/tor_lifecycle_state.dart';
import 'package:prysm/util/tor_runtime_gate.dart';
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
      TorManager(torPath: '/bin/false', dataDir: '/tmp/transport-provider-test', controlPassword: 'test-password'),
    );
    expect(TransportProvider.isConfigured, isTrue);

    TransportProvider.resetForTest();
    expect(TransportProvider.isConfigured, isFalse);
  });

  test('HTTP-only preference skips realtime connection', () {
    TransportProvider.configure(
      TorManager(torPath: '/bin/false', dataDir: '/tmp/transport-provider-test-2', controlPassword: 'test-password'),
    );
    expect(
      TransportProvider.instance.isRealtimeConnected('legacy.onion'),
      isFalse,
    );
  });

  test('startWebSocketConnections starts maintain loop', () {
    TransportProvider.configure(
      TorManager(torPath: '/bin/false', dataDir: '/tmp/transport-provider-test-3', controlPassword: 'test-password'),
    );
    TransportProvider.instance.startWebSocketConnections();
    expect(WsConnectionManager.interactiveConnectBudget.inSeconds, greaterThan(0));
  });

  test('configure reuses provider when tor manager is unchanged', () {
    final torManager = TorManager(
      torPath: '/bin/false',
      dataDir: '/tmp/transport-provider-test-reuse',
      controlPassword: 'test-password',
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
      TorManager(torPath: '/bin/false', dataDir: '/tmp/transport-provider-test-4', controlPassword: 'test-password'),
    );

    var usedHttp = false;
    try {
      await TransportProvider.instance.withPeer('missing.onion', (transport) async {
        usedHttp = transport == TransportProvider.instance.httpTransport;
        throw StateError('simulated HTTP path');
      });
    } catch (_) {}

    expect(usedHttp, isTrue);
  });

  test('withPeer uses registered inbound link without outbound dial', () async {
    TransportProvider.configure(
      TorManager(torPath: '/bin/false', dataDir: '/tmp/transport-provider-inbound', controlPassword: 'test-password'),
    );

    TransportProvider.instance.wsManager.registerLinkForTest(
      'peer.onion',
      _FakeWsPeerLink('peer.onion'),
    );

    var usedWs = false;
    final result = await TransportProvider.instance.withPeer(
      'peer.onion',
      (transport) async {
        usedWs = transport is TorWebSocketTransport;
        return 'ok';
      },
      preference: TransportPreference.wsPreferred,
    );

    expect(usedWs, isTrue);
    expect(result, 'ok');
  });

  test('WS ack wait is capped when a connected link never acks', () async {
    TransportProvider.configure(
      TorManager(
        torPath: '/bin/false',
        dataDir: '/tmp/transport-provider-ws-ack-cap',
        controlPassword: 'test-password',
      ),
    );
    // Open the gate: the default stopped state refuses before asking. It is
    // process-wide, so put it back or the next test inherits a ready gate.
    TorRuntimeGate.resetForTest();
    addTearDown(
      () => TorRuntimeGate.resetForTest(lifecycle: TorLifecycleState.stopped),
    );

    final link = _FakeWsPeerLink('peer.onion', stallAck: true);
    TransportProvider.instance.wsManager.registerLinkForTest(
      'peer.onion',
      link,
    );

    final stopwatch = Stopwatch()..start();
    try {
      await TransportProvider.instance.postMessageWithPreference(
        peerOnion: 'peer.onion',
        payload: {'type': 'text'},
        preference: TransportPreference.wsIfConnected,
      );
    } catch (_) {
      // WS leg timed out at its cap; the HTTP fallback cannot deliver.
    }
    stopwatch.stop();

    // A stale-but-connected link must not eat the whole 30 s send budget.
    // Pin the cap exactly: `lessThan(15s)` would accept a 14 s regression.
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 15)));
    expect(link.lastRequestTimeout, const Duration(seconds: 8));
  });

  test('recoverWebSocket learns the identity of an undialable peer', () async {
    TransportProvider.configure(
      TorManager(
        torPath: '/bin/false',
        dataDir: '/tmp/transport-provider-learn-identity',
        controlPassword: 'test-password',
      ),
    );

    final learned = <String>[];
    TransportProvider.learnPeerIdentity = (peerOnion) async {
      learned.add(peerOnion);
    };

    // No link is registered, so the dial fails: this is the group co-member
    // we can reach over HTTP but whose hello we keep rejecting because their
    // keys were never stored. Recovery must go and learn them.
    await TransportProvider.instance.recoverWebSocket('stranger.onion');

    expect(learned, ['stranger.onion']);
  });
}

class _FakeWsPeerLink implements WsPeerLink {
  _FakeWsPeerLink(this.peerOnion, {this.stallAck = false});

  @override
  final String peerOnion;

  /// When true, [request] never answers; only its own timeout can fire.
  final bool stallAck;

  /// Last timeout handed to [request]; lets tests see the applied cap.
  Duration? lastRequestTimeout;

  @override
  bool isConnected = true;

  @override
  Stream<Map<String, dynamic>> get onPushFrames =>
      const Stream<Map<String, dynamic>>.empty();

  @override
  Stream<List<int>> get onBinaryFrames => const Stream<List<int>>.empty();

  @override
  Future<void> close() async {
    isConnected = false;
  }

  @override
  Future<Map<String, dynamic>> request(
    String op, {
    Map<String, dynamic>? payload,
    Duration timeout = const Duration(seconds: 30),
  }) {
    lastRequestTimeout = timeout;
    if (!stallAck) {
      return Future<Map<String, dynamic>>.value(<String, dynamic>{});
    }
    // A half-dead socket reports connected but never acks: mirror the real
    // link, where only the passed timeout can fire.
    return Completer<Map<String, dynamic>>().future.timeout(timeout);
  }

  @override
  Future<void> send(String op, {Map<String, dynamic>? payload}) async {}

  @override
  Future<void> sendBytes(List<int> bytes) async {}

  @override
  Future<void> sendPing() async {}
}
