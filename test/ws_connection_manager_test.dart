import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/services/ws_connection_manager.dart';
import 'package:prysm/transport/ws_dial_policy.dart';
import 'package:prysm/transport/ws_peer_link.dart';
import 'package:prysm/util/tor_runtime_gate.dart';
import 'package:prysm/util/tor_service.dart';

void main() {
  setUp(() {
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

  test('acceptor waits for inbound link instead of dialing', () async {
    final manager = WsConnectionManager(
      TorManager(torPath: '/bin/false', dataDir: '/tmp/ws-manager-acceptor'),
    );

    const localOnion = 'bbb.onion';
    const peerOnion = 'aaa.onion';
    expect(shouldDialPeer(localOnion: localOnion, peerOnion: peerOnion), isFalse);

    manager.start();
    final waitFuture = manager.ensureConnected(
      peerOnion,
      connectBudget: const Duration(milliseconds: 50),
    );

    await expectLater(waitFuture, throwsA(isA<StateError>()));
    manager.dispose();
  });

  test('registerLinkForTest marks peer connected', () {
    final manager = WsConnectionManager(
      TorManager(torPath: '/bin/false', dataDir: '/tmp/ws-manager-inbound'),
    );

    final link = _FakeWsPeerLink('peer.onion');
    manager.registerLinkForTest('peer.onion', link);
    expect(manager.isConnected('peer.onion'), isTrue);

    manager.dispose();
  });

  test('prepareForTorReconnect clears links', () {
    final manager = WsConnectionManager(
      TorManager(torPath: '/bin/false', dataDir: '/tmp/ws-manager-reconnect'),
    );

    manager.registerLinkForTest('peer.onion', _FakeWsPeerLink('peer.onion'));
    expect(manager.isConnected('peer.onion'), isTrue);

    manager.prepareForTorReconnect();
    expect(manager.isConnected('peer.onion'), isFalse);

    manager.dispose();
  });
}

class _FakeWsPeerLink implements WsPeerLink {
  _FakeWsPeerLink(this.peerOnion);

  @override
  final String peerOnion;

  @override
  bool isConnected = true;

  @override
  Stream<Map<String, dynamic>> get onPushFrames =>
      const Stream<Map<String, dynamic>>.empty();

  @override
  Future<void> close() async {
    isConnected = false;
  }

  @override
  Future<Map<String, dynamic>> request(
    String op, {
    Map<String, dynamic>? payload,
    Duration timeout = const Duration(seconds: 30),
  }) async =>
      <String, dynamic>{};

  @override
  Future<void> send(String op, {Map<String, dynamic>? payload}) async {}

  @override
  Future<void> sendPing() async {}
}
