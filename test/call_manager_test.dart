import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/crypto/identity.dart';
import 'package:prysm/services/call/audio_engine.dart';
import 'package:prysm/services/call/call_foreground_session.dart';
import 'package:prysm/services/call/call_manager.dart';
import 'package:prysm/services/call/call_session.dart';
import 'package:prysm/services/call/call_signaling_notifier.dart';
import 'package:prysm/services/call/call_transport.dart';
import 'package:prysm/util/key_manager.dart';

// Manual verification (not automated):
// 1. Android active call: start call, press Home, verify bidirectional audio ~60s.
// 2. Android incoming: background app, call from desktop, Accept on notification.
// 3. Android decline: incoming notification Decline ends call for caller.
// 4. Linux: start call, minimize to tray; close window during call keeps tray + audio.
// 5. Battery saver on mid-call: WS peer should stay connected ~60s.

void main() {
  late _FakeTransport transport;
  late _FakeKeyResolver keyResolver;
  late KeyManager keyManager;
  late CallSignalingNotifier notifier;
  late CallManager manager;
  late _RecordingForegroundSession foreground;

  late IdentityPublicKeys peerKeys;
  late IdentityPublicKeys localKeys;

  setUp(() async {
    final local = await IdentityKeyPair.generate();
    final peer = await IdentityKeyPair.generate();
    keyManager = KeyManager.fromIdentity(local);
    localKeys = IdentityPublicKeys(
      signPublic: await local.signPublicKey,
      agreePublic: await local.agreePublicKey,
      fingerprint: 'local',
    );
    peerKeys = IdentityPublicKeys(
      signPublic: await peer.signPublicKey,
      agreePublic: await peer.agreePublicKey,
      fingerprint: 'test',
    );
    transport = _FakeTransport();
    keyResolver = _FakeKeyResolver(peerKeys);
    notifier = CallSignalingNotifier();
    CallSignalingNotifier.testInstance = notifier;
    CallManager.resetForTest();
    foreground = _RecordingForegroundSession();
    CallForegroundSession.testOverride = foreground;
    manager = CallManager(
      keyManager: keyManager,
      transport: transport,
      keyResolver: keyResolver,
      audioFactory: ({required session, required onSendFrame}) => _FakeCallAudio(
        onSendFrame: onSendFrame,
      ),
    );
    manager.start();
  });

  tearDown(() {
    CallSignalingNotifier.testInstance = null;
    CallManager.resetForTest();
  });

  test('answer received while offer send is pending activates call', () async {
    final sendGate = Completer<void>();
    transport.offerSendGate = sendGate;

    final done = Completer<void>();
    manager.addListener(() {
      if (manager.snapshot.state == CallState.active) {
        done.complete();
      }
    });

    unawaited(manager.startCall('peer.onion'));
    await Future<void>.delayed(Duration.zero);
    expect(manager.snapshot.state, CallState.ringing);
    expect(
      transport.sentFrames.where((f) => f.op == 'call_offer'),
      isEmpty,
    );

    notifier.applyInbound('peer.onion', 'call_answer', {
      'callId': manager.snapshot.callId,
      'sessionId': 1,
    });
    sendGate.complete();

    await done.future.timeout(const Duration(seconds: 2));
    expect(manager.snapshot.state, CallState.active);
  });

  test('outbound call becomes active after answer', () async {
    final done = Completer<void>();
    manager.addListener(() {
      if (manager.snapshot.state == CallState.active) {
        done.complete();
      }
    });

    await manager.startCall('peer.onion');
    expect(manager.snapshot.state, CallState.ringing);

    final offer = transport.sentFrames
        .firstWhere((f) => f.op == 'call_offer');
    notifier.applyInbound('peer.onion', 'call_answer', {
      'callId': offer.payload['callId'],
      'sessionId': offer.payload['sessionId'],
    });

    await done.future.timeout(const Duration(seconds: 2));
    expect(manager.snapshot.state, CallState.active);
  });

  test('remote call_end ends active call', () async {
    final caller = CallSession.createOutbound(
      callId: 'end-test',
      sessionId: 9,
      peerOnion: 'local.onion',
    );
    notifier.applyInbound('peer.onion', 'call_offer', {
      'callId': caller.callId,
      'sessionId': caller.sessionId,
      'wrappedKey': await caller.wrapKeyForPeer(
        localKeys,
        keyManager,
      ),
    });
    await Future<void>.delayed(Duration.zero);
    await manager.acceptIncoming();
    expect(manager.snapshot.state, CallState.active);

    notifier.applyInbound('peer.onion', 'call_end', {
      'callId': caller.callId,
      'reason': 'hangup',
    });
    await Future<void>.delayed(Duration.zero);
    expect(manager.snapshot.state, CallState.idle);
  });

  test('incoming offer can be accepted', () async {
    final caller = CallSession.createOutbound(
      callId: 'incoming-1',
      sessionId: 5,
      peerOnion: 'local.onion',
    );
    notifier.applyInbound('peer.onion', 'call_offer', {
      'callId': caller.callId,
      'sessionId': caller.sessionId,
      'wrappedKey': await caller.wrapKeyForPeer(
        localKeys,
        keyManager,
      ),
    });

    await Future<void>.delayed(Duration.zero);
    expect(manager.snapshot.state, CallState.incoming);
    await manager.acceptIncoming();
    expect(manager.snapshot.state, CallState.active);
  });

  test('foreground session syncs on call state transitions', () async {
    final caller = CallSession.createOutbound(
      callId: 'fg-1',
      sessionId: 3,
      peerOnion: 'local.onion',
    );
    notifier.applyInbound('peer.onion', 'call_offer', {
      'callId': caller.callId,
      'sessionId': caller.sessionId,
      'wrappedKey': await caller.wrapKeyForPeer(
        localKeys,
        keyManager,
      ),
    });
    await Future<void>.delayed(Duration.zero);
    expect(foreground.syncCalls, isNotEmpty);
    expect(foreground.lastActive, isTrue);

    await manager.rejectIncoming();
    await Future<void>.delayed(Duration.zero);
    expect(foreground.lastActive, isFalse);
  });
}

class _RecordingForegroundSession implements CallForegroundSessionPort {
  final syncCalls = <CallSnapshot>[];
  bool lastActive = false;

  @override
  bool get inCall => lastActive;

  @override
  Future<void> sync(CallSnapshot snapshot, {CallSnapshot? previous}) async {
    syncCalls.add(snapshot);
    lastActive = snapshot.isInCall;
  }

  @override
  Future<void> onAppLifecycleChanged(AppLifecycleState state) async {}
}

class _FakeTransport implements CallTransport {
  final sentFrames = <_SentFrame>[];
  final _binaryControllers = <String, StreamController<List<int>>>{};
  Completer<void>? offerSendGate;

  @override
  Future<void> ensureConnected(String peerOnion) async {}

  @override
  Future<void> send(
    String peerOnion,
    String op,
    Map<String, dynamic> payload,
  ) async {
    if (op == 'call_offer' && offerSendGate != null) {
      await offerSendGate!.future;
    }
    sentFrames.add(_SentFrame(op, Map<String, dynamic>.from(payload)));
  }

  @override
  Future<void> sendBytes(String peerOnion, Uint8List bytes) async {}

  @override
  void pinPeer(String peerOnion) {}

  @override
  void unpinPeer(String peerOnion) {}

  @override
  Stream<List<int>> binaryFramesFor(String peerOnion) {
    return (_binaryControllers[peerOnion] ??=
            StreamController<List<int>>.broadcast())
        .stream;
  }
}

class _SentFrame {
  _SentFrame(this.op, this.payload);
  final String op;
  final Map<String, dynamic> payload;
}

class _FakeKeyResolver implements CallKeyResolver {
  _FakeKeyResolver(this.key);
  final IdentityPublicKeys key;

  @override
  Future<IdentityPublicKeys?> resolve(String peerOnion) async => key;
}

class _FakeCallAudio implements CallAudio {
  _FakeCallAudio({required this.onSendFrame});

  final void Function(Uint8List encryptedFrame) onSendFrame;

  @override
  bool get isMuted => false;

  @override
  bool get isRunning => true;

  @override
  Future<bool> start() async => true;

  @override
  Future<void> stop() async {}

  @override
  void handleIncoming(Uint8List encryptedFrame) {}

  @override
  void setMuted(bool muted) {}
}
