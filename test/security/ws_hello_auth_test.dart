import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/crypto/crypto.dart';
import 'package:prysm/services/ws_connection_manager.dart';
import 'package:prysm/transport/inbound_ws_peer_link.dart';
import 'package:prysm/transport/ws_frame_router.dart';
import 'package:prysm/transport/ws_peer_link.dart';
import 'package:prysm/util/tor_service.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

// Local onion sorts after every peer onion so the dial-policy check
// (localOnion.compareTo(peerOnion) < 0) never short-circuits the handshake.
const String localOnion = 'zzz-local.onion';
const String peerOnion = 'aaa-peer.onion';
const String otherOnion = 'mmm-other.onion';

Future<IdentityPublicKeys> _publicKeys(IdentityKeyPair id) async {
  final sign = await id.signPublicKey;
  final agree = await id.agreePublicKey;
  return IdentityPublicKeys(
    signPublic: sign,
    agreePublic: agree,
    fingerprint: IdentityKeyPair.fingerprintFromPublicJson(
      await id.toPublicJson(),
    ),
  );
}

Future<String> _signHello({
  required IdentityKeyPair identity,
  required String senderOnion,
  required String receiverOnion,
  required int timestampMs,
}) =>
    PeerProof.sign(
      context: PeerProof.wsHelloContext,
      senderOnion: senderOnion,
      receiverOnion: receiverOnion,
      timestampMs: timestampMs,
      identity: identity,
    );

String _helloFrame({
  required String onion,
  int? timestampMs,
  String? signature,
}) =>
    jsonEncode({
      'v': 1,
      'op': 'hello',
      'payload': {
        'supports': <String>[],
        'onion': onion,
        'ts': ?timestampMs,
        'sig': ?signature,
      },
    });

Future<void> _pumpUntil(bool Function() condition) async {
  for (var i = 0; i < 200; i++) {
    if (condition()) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail('condition not reached within pump budget');
}

class _FakeWebSocketSink implements WebSocketSink {
  _FakeWebSocketSink(this._outgoing);

  final StreamController<dynamic> _outgoing;
  bool closed = false;

  @override
  Future add(dynamic event) async => _outgoing.add(event);

  @override
  Future addError(Object error, [StackTrace? stackTrace]) async =>
      _outgoing.addError(error, stackTrace ?? StackTrace.current);

  @override
  Future addStream(Stream<dynamic> stream) => _outgoing.addStream(stream);

  @override
  Future close([int? closeCode, String? reason]) async {
    closed = true;
    await _outgoing.close();
  }

  @override
  Future get done => _outgoing.done;
}

class _FakeWebSocketChannel implements WebSocketChannel {
  final StreamController<dynamic> _outgoing =
      StreamController<dynamic>.broadcast();
  final StreamController<dynamic> _incoming =
      StreamController<dynamic>.broadcast();
  late final _FakeWebSocketSink _sink;

  final List<dynamic> sent = [];

  _FakeWebSocketChannel() {
    _sink = _FakeWebSocketSink(_outgoing);
    _outgoing.stream.listen(sent.add);
  }

  void receive(dynamic data) => _incoming.add(data);

  _FakeWebSocketSink get fakeSink => _sink;

  @override
  Stream<dynamic> get stream => _incoming.stream;

  @override
  WebSocketSink get sink => _sink;

  @override
  Future<void> get ready => Future.value();

  @override
  String? get protocol => null;

  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;

  // The link under test only touches [stream] and [sink]; the remaining
  // StreamChannelMixin members (pipe, transform, ...) are never invoked.
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _CapturingWsConnectionManager extends WsConnectionManager {
  _CapturingWsConnectionManager()
      : super(
          TorManager(
            torPath: 'unused',
            dataDir: 'unused',
            controlPassword: 'unused',
          ),
        );

  InboundWsPeerLink? registeredLink;
  int registerCount = 0;

  @override
  void registerInboundLink(InboundWsPeerLink link) {
    registeredLink = link;
    registerCount++;
  }
}

/// Minimal connected link so a manager can be pre-populated with a peer.
class _FakeWsPeerLink implements WsPeerLink {
  _FakeWsPeerLink(this.peerOnion);

  @override
  final String peerOnion;

  @override
  bool get isConnected => true;

  @override
  Stream<Map<String, dynamic>> get onPushFrames => const Stream.empty();

  @override
  Stream<List<int>> get onBinaryFrames => const Stream.empty();

  @override
  Future<void> send(String op, {Map<String, dynamic>? payload}) async {}

  @override
  Future<void> sendBytes(List<int> bytes) async {}

  @override
  Future<Map<String, dynamic>> request(
    String op, {
    Map<String, dynamic>? payload,
    Duration timeout = const Duration(seconds: 30),
  }) async =>
      <String, dynamic>{};

  @override
  Future<void> sendPing() async {}

  @override
  Future<void> close() async {}
}

void main() {
  test('hello with a valid proof completes the handshake and registers', () async {
    final peer = await IdentityKeyPair.generate();
    final peerPub = await _publicKeys(peer);
    final channel = _FakeWebSocketChannel();
    final manager = _CapturingWsConnectionManager();

    InboundWsPeerLink.acceptIncoming(
      channel: channel,
      frameRouter: WsFrameRouter(),
      localOnion: () => localOnion,
      resolvePeerIdentity: (peerId) async => peerPub,
      manager: manager,
    );

    final ts = DateTime.now().millisecondsSinceEpoch;
    final sig = await _signHello(
      identity: peer,
      senderOnion: peerOnion,
      receiverOnion: localOnion,
      timestampMs: ts,
    );
    channel.receive(_helloFrame(onion: peerOnion, timestampMs: ts, signature: sig));

    await _pumpUntil(() => manager.registeredLink != null);
    expect(manager.registerCount, 1);
    expect(manager.registeredLink!.peerOnion, peerOnion);
    expect(manager.registeredLink!.isConnected, isTrue);
    // The link answered with a hello frame of its own.
    final reply = jsonDecode(channel.sent.first as String) as Map<String, dynamic>;
    expect(reply['op'], 'hello');
  });

  test('hello without a signature is rejected and never registers', () async {
    final peer = await IdentityKeyPair.generate();
    final peerPub = await _publicKeys(peer);
    final channel = _FakeWebSocketChannel();
    final manager = _CapturingWsConnectionManager();

    InboundWsPeerLink.acceptIncoming(
      channel: channel,
      frameRouter: WsFrameRouter(),
      localOnion: () => localOnion,
      resolvePeerIdentity: (peerId) async => peerPub,
      manager: manager,
    );

    final ts = DateTime.now().millisecondsSinceEpoch;
    channel.receive(_helloFrame(onion: peerOnion, timestampMs: ts));

    await _pumpUntil(() => channel.fakeSink.closed);
    expect(channel.fakeSink.closed, isTrue);
    expect(manager.registeredLink, isNull);
    expect(channel.sent, isEmpty);
  });

  test('hello signed by a different identity than the resolver returns is rejected',
      () async {
    final peer = await IdentityKeyPair.generate();
    final attacker = await IdentityKeyPair.generate();
    final peerPub = await _publicKeys(peer);
    final channel = _FakeWebSocketChannel();
    final manager = _CapturingWsConnectionManager();

    InboundWsPeerLink.acceptIncoming(
      channel: channel,
      frameRouter: WsFrameRouter(),
      localOnion: () => localOnion,
      resolvePeerIdentity: (peerId) async => peerPub,
      manager: manager,
    );

    final ts = DateTime.now().millisecondsSinceEpoch;
    final sig = await _signHello(
      identity: attacker,
      senderOnion: peerOnion,
      receiverOnion: localOnion,
      timestampMs: ts,
    );
    channel.receive(_helloFrame(onion: peerOnion, timestampMs: ts, signature: sig));

    await _pumpUntil(() => channel.fakeSink.closed);
    expect(channel.fakeSink.closed, isTrue);
    expect(manager.registeredLink, isNull);
  });

  test('hello signed for a different receiver onion is rejected', () async {
    final peer = await IdentityKeyPair.generate();
    final peerPub = await _publicKeys(peer);
    final channel = _FakeWebSocketChannel();
    final manager = _CapturingWsConnectionManager();

    InboundWsPeerLink.acceptIncoming(
      channel: channel,
      frameRouter: WsFrameRouter(),
      localOnion: () => localOnion,
      resolvePeerIdentity: (peerId) async => peerPub,
      manager: manager,
    );

    final ts = DateTime.now().millisecondsSinceEpoch;
    final sig = await _signHello(
      identity: peer,
      senderOnion: peerOnion,
      receiverOnion: otherOnion,
      timestampMs: ts,
    );
    channel.receive(_helloFrame(onion: peerOnion, timestampMs: ts, signature: sig));

    await _pumpUntil(() => channel.fakeSink.closed);
    expect(channel.fakeSink.closed, isTrue);
    expect(manager.registeredLink, isNull);
  });

  test('hello with a timestamp older than maxSkew is rejected', () async {
    final peer = await IdentityKeyPair.generate();
    final peerPub = await _publicKeys(peer);
    final channel = _FakeWebSocketChannel();
    final manager = _CapturingWsConnectionManager();

    InboundWsPeerLink.acceptIncoming(
      channel: channel,
      frameRouter: WsFrameRouter(),
      localOnion: () => localOnion,
      resolvePeerIdentity: (peerId) async => peerPub,
      manager: manager,
    );

    final staleTs = DateTime.now().millisecondsSinceEpoch -
        PeerProof.maxSkew.inMilliseconds -
        60 * 1000;
    final sig = await _signHello(
      identity: peer,
      senderOnion: peerOnion,
      receiverOnion: localOnion,
      timestampMs: staleTs,
    );
    channel.receive(_helloFrame(onion: peerOnion, timestampMs: staleTs, signature: sig));

    await _pumpUntil(() => channel.fakeSink.closed);
    expect(channel.fakeSink.closed, isTrue);
    expect(manager.registeredLink, isNull);
  });

  test('hello for an onion the resolver does not know is rejected', () async {
    final channel = _FakeWebSocketChannel();
    final manager = _CapturingWsConnectionManager();

    InboundWsPeerLink.acceptIncoming(
      channel: channel,
      frameRouter: WsFrameRouter(),
      localOnion: () => localOnion,
      resolvePeerIdentity: (peerId) async => null,
      manager: manager,
    );

    final ts = DateTime.now().millisecondsSinceEpoch;
    final sig = await _signHello(
      identity: await IdentityKeyPair.generate(),
      senderOnion: peerOnion,
      receiverOnion: localOnion,
      timestampMs: ts,
    );
    channel.receive(_helloFrame(onion: peerOnion, timestampMs: ts, signature: sig));

    await _pumpUntil(() => channel.fakeSink.closed);
    expect(channel.fakeSink.closed, isTrue);
    expect(manager.registeredLink, isNull);
  });

  test(
      'unsigned hello is dropped identically whether or not the claimed onion '
      'is linked', () async {
    // The presence oracle: an unauthenticated hello claiming a linked
    // contact's onion used to draw the informative 'duplicate' reply while
    // the same hello for an unlinked onion was silently dropped — two
    // distinguishable responses to an unproven claim. Proof now runs first,
    // so both cases must be byte-identical: silent close, no frames sent,
    // nothing registered, peerOnion never assigned.
    final peer = await IdentityKeyPair.generate();
    final peerPub = await _publicKeys(peer);

    Future<(_FakeWebSocketChannel, _CapturingWsConnectionManager)> run(
      bool linked,
    ) async {
      final channel = _FakeWebSocketChannel();
      final manager = _CapturingWsConnectionManager();
      if (linked) {
        manager.registerLinkForTest(peerOnion, _FakeWsPeerLink(peerOnion));
      }
      InboundWsPeerLink.acceptIncoming(
        channel: channel,
        frameRouter: WsFrameRouter(),
        localOnion: () => localOnion,
        resolvePeerIdentity: (peerId) async => peerPub,
        manager: manager,
      );
      channel.receive(_helloFrame(onion: linked ? peerOnion : otherOnion));
      await _pumpUntil(() => channel.fakeSink.closed);
      return (channel, manager);
    }

    final (linkedChannel, linkedManager) = await run(true);
    final (unlinkedChannel, unlinkedManager) = await run(false);

    // The oracle-closed proof: both cases emit exactly the same frames
    // (none). If the duplicate check were reverted to run before the proof,
    // the linked case would emit hello + 'duplicate' error frames and this
    // equality would fail.
    expect(linkedChannel.sent, unlinkedChannel.sent);
    expect(linkedChannel.sent, isEmpty);
    expect(linkedChannel.fakeSink.closed, isTrue);
    expect(unlinkedChannel.fakeSink.closed, isTrue);
    expect(linkedManager.registeredLink, isNull);
    expect(linkedManager.registerCount, 0);
    expect(unlinkedManager.registeredLink, isNull);
    expect(unlinkedManager.registerCount, 0);
    // The rejected link never completed and never assigned peerOnion: the
    // pre-registered link survives (close() with an empty peerOnion cannot
    // unregister it), and the unlinked onion was never registered.
    expect(linkedManager.isConnected(peerOnion), isTrue);
    expect(unlinkedManager.isConnected(otherOnion), isFalse);
    expect(unlinkedManager.hasLink(otherOnion), isFalse);
  });

  test('valid proof for an already-linked onion still gets the duplicate reply',
      () async {
    final peer = await IdentityKeyPair.generate();
    final peerPub = await _publicKeys(peer);
    final channel = _FakeWebSocketChannel();
    final manager = _CapturingWsConnectionManager();
    manager.registerLinkForTest(peerOnion, _FakeWsPeerLink(peerOnion));

    InboundWsPeerLink.acceptIncoming(
      channel: channel,
      frameRouter: WsFrameRouter(),
      localOnion: () => localOnion,
      resolvePeerIdentity: (peerId) async => peerPub,
      manager: manager,
    );

    final ts = DateTime.now().millisecondsSinceEpoch;
    final sig = await _signHello(
      identity: peer,
      senderOnion: peerOnion,
      receiverOnion: localOnion,
      timestampMs: ts,
    );
    channel.receive(_helloFrame(onion: peerOnion, timestampMs: ts, signature: sig));

    await _pumpUntil(() => channel.fakeSink.closed);
    // The proof verified, so the legitimate duplicate path is still taken.
    expect(channel.sent.length, 2);
    final helloReply =
        jsonDecode(channel.sent[0] as String) as Map<String, dynamic>;
    expect(helloReply['op'], 'hello');
    expect(
      (helloReply['payload'] as Map<String, dynamic>)['onion'],
      localOnion,
    );
    final errorReply =
        jsonDecode(channel.sent[1] as String) as Map<String, dynamic>;
    expect(errorReply['op'], 'error');
    expect(errorReply['id'], 'duplicate');
    expect(
      (errorReply['payload'] as Map<String, dynamic>)['error'],
      'duplicate connection',
    );
    expect(manager.registeredLink, isNull);
    expect(manager.registerCount, 0);
    // The duplicate path never assigned peerOnion, so the pre-existing link
    // is untouched.
    expect(manager.isConnected(peerOnion), isTrue);
  });

  test('hello whose claimed onion has no cached identity is rejected silently',
      () async {
    // The handshake resolver is cache-only (PrysmServer passes
    // loadPeerIdentityFromDb); a cache miss returns null and must produce the
    // same silent drop as every other unproven hello — no frames at all, so
    // the null case can never act as an oracle either.
    final peer = await IdentityKeyPair.generate();
    final channel = _FakeWebSocketChannel();
    final manager = _CapturingWsConnectionManager();

    InboundWsPeerLink.acceptIncoming(
      channel: channel,
      frameRouter: WsFrameRouter(),
      localOnion: () => localOnion,
      resolvePeerIdentity: (peerId) async => null,
      manager: manager,
    );

    final ts = DateTime.now().millisecondsSinceEpoch;
    final sig = await _signHello(
      identity: peer,
      senderOnion: peerOnion,
      receiverOnion: localOnion,
      timestampMs: ts,
    );
    channel.receive(_helloFrame(onion: peerOnion, timestampMs: ts, signature: sig));

    await _pumpUntil(() => channel.fakeSink.closed);
    expect(channel.sent, isEmpty);
    expect(channel.fakeSink.closed, isTrue);
    expect(manager.registeredLink, isNull);
    expect(manager.registerCount, 0);
  });
}
