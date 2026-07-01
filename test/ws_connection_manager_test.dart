import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/services/ws_connection_manager.dart';
import 'package:prysm/transport/ws_peer_link.dart';
import 'package:prysm/util/tor_lifecycle_state.dart';
import 'package:prysm/util/tor_runtime_gate.dart';
import 'package:prysm/util/tor_service.dart';

void main() {
  setUp(() {
    TorRuntimeGate.resetForTest();
  });

  tearDown(() {
    TorRuntimeGate.resetForTest(lifecycle: TorLifecycleState.stopped);
  });

  test('interactive connect budget is 25 seconds', () {
    expect(
      WsConnectionManager.interactiveConnectBudget,
      const Duration(seconds: 25),
    );
  });

  test('ensureConnected rejects when Tor is stopped', () async {
    TorRuntimeGate.resetForTest(lifecycle: TorLifecycleState.stopped);
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

  test('request calls are serialized per peer', () async {
    final manager = WsConnectionManager(
      TorManager(torPath: '/bin/false', dataDir: '/tmp/ws-manager-queue'),
    );
    final link = _RecordingWsPeerLink('peer.onion');
    manager.registerLinkForTest('peer.onion', link);

    final first = manager.request('peer.onion', 'first');
    final second = manager.request('peer.onion', 'second');
    await Future.wait([first, second]);

    expect(link.ops, ['first', 'second']);
    manager.dispose();
  });
}

class _RecordingWsPeerLink implements WsPeerLink {
  _RecordingWsPeerLink(this.peerOnion);

  @override
  final String peerOnion;

  final List<String> ops = [];

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
  }) async {
    ops.add(op);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    return <String, dynamic>{};
  }

  @override
  Future<void> send(String op, {Map<String, dynamic>? payload}) async {}

  @override
  Future<void> sendBytes(List<int> bytes) async {}

  @override
  Future<void> sendPing() async {}
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
  }) async =>
      <String, dynamic>{};

  @override
  Future<void> send(String op, {Map<String, dynamic>? payload}) async {}

  @override
  Future<void> sendBytes(List<int> bytes) async {}

  @override
  Future<void> sendPing() async {}
}
