import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:prysm/database/call_logs_db.dart';
import 'package:prysm/database/messages.dart';
import 'package:prysm/services/block_service.dart';
import 'package:prysm/services/call/audio_engine.dart';
import 'package:prysm/services/call/call_session.dart';
import 'package:prysm/services/call/opus_codec.dart';
import 'package:prysm/services/call/call_foreground_session.dart';
import 'package:prysm/services/call/call_logs_service.dart';
import 'package:prysm/services/call/call_signaling_notifier.dart';
import 'package:prysm/services/call/call_transport.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/local_onion_address.dart';
import 'package:prysm/util/logging.dart';
import 'package:uuid/uuid.dart';

enum CallState { idle, connecting, ringing, incoming, active, ended }

class CallSnapshot {
  const CallSnapshot({
    required this.state,
    this.peerOnion,
    this.callId,
    this.peerMuted = false,
    this.localMuted = false,
    this.error,
    this.activeSince,
  });

  final CallState state;
  final String? peerOnion;
  final String? callId;
  final bool peerMuted;
  final bool localMuted;
  final String? error;
  final DateTime? activeSince;

  bool get isInCall =>
      state == CallState.connecting ||
      state == CallState.ringing ||
      state == CallState.incoming ||
      state == CallState.active;
}

typedef CallAudioFactory =
    CallAudio Function({
      required CallSession session,
      required CallAudioSendCallback onSendFrame,
    });

class CallManager extends ChangeNotifier {
  CallManager({
    required KeyManager keyManager,
    CallTransport? transport,
    CallKeyResolver? keyResolver,
    CallAudioFactory? audioFactory,
  }) : _keyManager = keyManager,
       _transport = transport,
       _keyResolver = keyResolver,
       _audioFactory = audioFactory ?? createCallAudio;

  static CallManager? _instance;

  static CallManager get instance {
    final i = _instance;
    if (i == null) {
      throw StateError('CallManager.start() must be called first');
    }
    return i;
  }

  static void configure({
    required KeyManager keyManager,
    CallTransport? transport,
    CallKeyResolver? keyResolver,
    CallAudioFactory? audioFactory,
  }) {
    final existing = _instance;
    if (existing != null && identical(existing._keyManager, keyManager)) {
      return;
    }
    existing?._shutdown();
    _instance = CallManager(
      keyManager: keyManager,
      transport: transport,
      keyResolver: keyResolver,
      audioFactory: audioFactory,
    );
  }

  @visibleForTesting
  static void resetForTest() {
    _instance?._shutdown();
    _instance = null;
    CallForegroundSession.resetState();
  }

  /// Ends an active call with [peerOnion] if one is in progress.
  static Future<void> endCallWithPeer(
    String peerOnion, {
    String reason = 'declined',
  }) async {
    final mgr = _instance;
    if (mgr == null || mgr._shuttingDown) return;
    if (!mgr._snapshot.isInCall || mgr._snapshot.peerOnion != peerOnion) {
      return;
    }
    final callId = mgr._snapshot.callId;
    if (callId != null) {
      await mgr._sendEnd(peerOnion, callId, reason: reason);
    }
    await mgr._teardown();
    mgr._setSnapshot(const CallSnapshot(state: CallState.idle));
  }

  final KeyManager _keyManager;
  CallTransport? _transport;
  CallKeyResolver? _keyResolver;
  final CallAudioFactory _audioFactory;

  StreamSubscription<CallSignalEvent>? _signalSub;
  StreamSubscription<List<int>>? _binarySub;
  CallAudio? _audio;
  CallSession? _session;
  Timer? _ringTimer;
  bool _incomingActionInFlight = false;
  bool _shuttingDown = false;
  int _audioSendFailures = 0;
  String? _currentCallId;
  CallLogDirection? _currentCallDirection;
  int? _currentCallStartedAt;
  bool _callLogFinalized = false;

  CallSnapshot _snapshot = const CallSnapshot(state: CallState.idle);

  CallSnapshot get snapshot => _snapshot;

  void start() {
    if (_signalSub != null) return;
    _transport ??= defaultCallTransport();
    _keyResolver ??= DbCallKeyResolver(_keyManager);
    final transport = _transport;
    if (transport is WsCallTransport) {
      transport.manager.onPeerDisconnected = _onPeerDisconnected;
    }
    _signalSub = CallSignalingNotifier.active.events.listen(_onSignal);
  }

  void _onPeerDisconnected(String peerOnion) {
    if (!_snapshot.isInCall) return;
    if (_snapshot.peerOnion != peerOnion) return;
    unawaited(_handleRemoteHangup());
  }

  Future<void> _handleRemoteHangup() async {
    if (!_snapshot.isInCall) return;
    await _finalizeCurrentLog();
    await _teardown();
    _setSnapshot(const CallSnapshot(state: CallState.idle));
  }

  Future<void> startCall(String peerOnion) async {
    if (_shuttingDown || _snapshot.isInCall) return;
    if (BlockService.instance.isBlocked(peerOnion)) return;

    _setSnapshot(
      CallSnapshot(state: CallState.connecting, peerOnion: peerOnion),
    );

    final transport = _transport!;
    final keyResolver = _keyResolver!;

    try {
      await transport.ensureConnected(peerOnion);
      transport.pinPeer(peerOnion);

      final peerKey = await keyResolver.resolve(peerOnion);
      if (peerKey == null) {
        await _fail('Could not resolve peer public key');
        return;
      }

      final callId = const Uuid().v4();
      final sessionId = Random.secure().nextInt(0x7fffffff);
      final session = CallSession.createOutbound(
        callId: callId,
        sessionId: sessionId,
        peerOnion: peerOnion,
      );
      _session = session;

      _setSnapshot(
        CallSnapshot(
          state: CallState.ringing,
          peerOnion: peerOnion,
          callId: callId,
        ),
      );
      _startCallLog(
        callId: callId,
        peerOnion: peerOnion,
        direction: CallLogDirection.outbound,
      );
      _startRingTimeout(peerOnion, callId);

      await transport.send(peerOnion, 'call_offer', {
        'callId': callId,
        'sessionId': sessionId,
        'wrappedKey': await session.wrapKeyForPeer(peerKey, _keyManager),
        'codec': {
          'sampleRate': session.codec.sampleRate,
          'channels': session.codec.channels,
          'frameDurationMs': session.codec.frameDurationMs,
        },
      });
    } catch (e) {
      await _fail('Failed to start call: $e');
    }
  }

  Future<void> acceptIncoming() async {
    if (_shuttingDown ||
        _incomingActionInFlight ||
        _snapshot.state != CallState.incoming) {
      return;
    }
    final peerOnion = _snapshot.peerOnion;
    final callId = _snapshot.callId;
    final session = _session;
    if (peerOnion == null || callId == null || session == null) return;

    _incomingActionInFlight = true;
    _ringTimer?.cancel();
    _setSnapshot(
      CallSnapshot(
        state: CallState.connecting,
        peerOnion: peerOnion,
        callId: callId,
      ),
    );

    try {
      final transport = _transport!;
      transport.pinPeer(peerOnion);

      await transport.send(peerOnion, 'call_answer', {
        'callId': callId,
        'sessionId': session.sessionId,
      });

      await _activateAudio(peerOnion, session);
    } finally {
      _incomingActionInFlight = false;
    }
  }

  Future<void> rejectIncoming() async {
    if (_shuttingDown ||
        _incomingActionInFlight ||
        _snapshot.state != CallState.incoming) {
      return;
    }
    final peerOnion = _snapshot.peerOnion;
    final callId = _snapshot.callId;
    if (peerOnion == null || callId == null) return;

    _incomingActionInFlight = true;
    _ringTimer?.cancel();
    try {
      await _sendEnd(peerOnion, callId, reason: 'declined');
      await _finalizeCurrentLog(status: CallLogStatus.declined);
      await _teardown();
      _setSnapshot(const CallSnapshot(state: CallState.idle));
    } finally {
      _incomingActionInFlight = false;
    }
  }

  /// Handles notification/tray decline when UI state may lag behind signaling.
  Future<void> declineFromNotification({
    required String callId,
    required String peerOnion,
  }) async {
    if (_shuttingDown) return;

    for (var attempt = 0; attempt < 15; attempt++) {
      final snap = _snapshot;
      if (snap.state == CallState.incoming &&
          snap.callId == callId &&
          snap.peerOnion == peerOnion) {
        await rejectIncoming();
        return;
      }
      if (!snap.isInCall) {
        if (attempt == 0) {
          await _sendEnd(peerOnion, callId, reason: 'declined');
        }
        return;
      }
      if (snap.peerOnion == peerOnion &&
          snap.callId == callId &&
          (snap.state == CallState.active ||
              snap.state == CallState.ringing ||
              snap.state == CallState.connecting)) {
        await endCall();
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }

    await _sendEnd(peerOnion, callId, reason: 'declined');
    if (_snapshot.isInCall && _snapshot.peerOnion == peerOnion) {
      await _teardown();
      _setSnapshot(const CallSnapshot(state: CallState.idle));
    }
  }

  Future<void> endCall() async {
    final peerOnion = _snapshot.peerOnion;
    final callId = _snapshot.callId;
    if (peerOnion != null && callId != null) {
      await _sendEnd(peerOnion, callId, reason: 'hangup');
    }
    await _finalizeCurrentLog();
    await _teardown();
    _setSnapshot(const CallSnapshot(state: CallState.idle));
  }

  Future<void> toggleMute() async {
    final muted = !_snapshot.localMuted;
    _audio?.setMuted(muted);
    final peerOnion = _snapshot.peerOnion;
    final callId = _snapshot.callId;
    if (peerOnion != null && callId != null) {
      await _transport?.send(peerOnion, 'call_mute', {
        'callId': callId,
        'muted': muted,
      });
    }
    _setSnapshot(
      CallSnapshot(
        state: _snapshot.state,
        peerOnion: _snapshot.peerOnion,
        callId: _snapshot.callId,
        peerMuted: _snapshot.peerMuted,
        localMuted: muted,
        activeSince: _snapshot.activeSince,
      ),
    );
  }

  Future<void> _onSignal(CallSignalEvent event) async {
    switch (event.op) {
      case CallSignalOp.offer:
        await _handleOffer(event);
      case CallSignalOp.answer:
        await _handleAnswer(event);
      case CallSignalOp.end:
        await _handleEnd(event);
      case CallSignalOp.mute:
        _handleMute(event);
    }
  }

  Future<void> _handleOffer(CallSignalEvent event) async {
    if (BlockService.instance.isBlocked(event.peerOnion)) {
      final callId = event.callId;
      if (callId != null) {
        await _sendEnd(event.peerOnion, callId, reason: 'declined');
      }
      return;
    }

    if (_snapshot.isInCall) {
      final callId = event.callId;
      if (callId != null) {
        await _sendEnd(event.peerOnion, callId, reason: 'busy');
      }
      return;
    }

    final payload = event.payload;
    final callId = event.callId;
    final sessionId = asInt(payload['sessionId']);
    final wrappedKey = payload['wrappedKey'] as String?;
    if (callId == null || sessionId == 0 || wrappedKey == null) return;

    try {
      final session = await CallSession.fromInbound(
        callId: callId,
        sessionId: sessionId,
        peerOnion: event.peerOnion,
        wrappedKey: wrappedKey,
        keyManager: _keyManager,
        codec: _codecFromPayload(payload['codec']),
      );
      _session = session;
      _transport?.pinPeer(event.peerOnion);
      _setSnapshot(
        CallSnapshot(
          state: CallState.incoming,
          peerOnion: event.peerOnion,
          callId: callId,
        ),
      );
      _startCallLog(
        callId: callId,
        peerOnion: event.peerOnion,
        direction: CallLogDirection.inbound,
      );
      _startRingTimeout(event.peerOnion, callId);
    } catch (e) {
      await _sendEnd(event.peerOnion, callId, reason: 'error');
    }
  }

  Future<void> _handleAnswer(CallSignalEvent event) async {
    if (_snapshot.state == CallState.active) return;
    if (_snapshot.state != CallState.ringing &&
        _snapshot.state != CallState.connecting) {
      return;
    }
    if (event.callId != _snapshot.callId) return;
    if (event.peerOnion != _snapshot.peerOnion) return;

    final session = _session;
    if (session == null) return;

    _ringTimer?.cancel();
    await _activateAudio(event.peerOnion, session);
  }

  Future<void> _handleEnd(CallSignalEvent event) async {
    if (!_snapshot.isInCall) return;
    final callId = event.callId;
    if (callId == null || callId != _snapshot.callId) return;
    if (event.peerOnion != _snapshot.peerOnion) return;
    await _finalizeCurrentLog();
    await _teardown();
    _setSnapshot(const CallSnapshot(state: CallState.idle));
  }

  void _handleMute(CallSignalEvent event) {
    if (event.callId != _snapshot.callId) return;
    if (event.peerOnion != _snapshot.peerOnion) return;
    final muted = event.payload['muted'] == true;
    _setSnapshot(
      CallSnapshot(
        state: _snapshot.state,
        peerOnion: _snapshot.peerOnion,
        callId: _snapshot.callId,
        peerMuted: muted,
        localMuted: _snapshot.localMuted,
        activeSince: _snapshot.activeSince,
      ),
    );
  }

  Future<void> _activateAudio(String peerOnion, CallSession session) async {
    if (_shuttingDown) return;
    _audioSendFailures = 0;
    final transport = _transport!;
    _binarySub?.cancel();
    _binarySub = transport.binaryFramesFor(peerOnion).listen((bytes) {
      _audio?.handleIncoming(Uint8List.fromList(bytes));
    });

    final audio = _audioFactory(
      session: session,
      onSendFrame: (frame) {
        unawaited(
          transport.sendBytes(peerOnion, frame).catchError((Object e) {
            _audioSendFailures++;
            if (kDebugMode) {
              Logging.error('sendBytes to $peerOnion failed (#$_audioSendFailures): $e', 'CallManager');
            }
          }),
        );
      },
    );
    _audio = audio;

    final started = await audio.start();
    if (!started) {
      await _fail(
        AudioEngine.lastStartError ??
            OpusCodec.lastLoadError ??
            'Could not start audio',
      );
      return;
    }

    if (_shuttingDown) {
      await audio.stop();
      return;
    }

    _setSnapshot(
      CallSnapshot(
        state: CallState.active,
        peerOnion: peerOnion,
        callId: session.callId,
        localMuted: _snapshot.localMuted,
        peerMuted: _snapshot.peerMuted,
        activeSince: DateTime.now(),
      ),
    );
  }

  Future<void> _startCallLog({
    required String callId,
    required String peerOnion,
    required CallLogDirection direction,
  }) async {
    _currentCallId = callId;
    _currentCallDirection = direction;
    _currentCallStartedAt = DateTime.now().millisecondsSinceEpoch;
    _callLogFinalized = false;
    try {
      await CallLogsDb.insertLog(
        callId: callId,
        peerOnion: peerOnion,
        direction: direction,
        status: CallLogStatus.ringing,
        startedAt: _currentCallStartedAt!,
      );
      CallLogsService.instance.notifyChanged();
    } catch (e) {
      if (kDebugMode) {
        Logging.error('failed to insert call log: $e', 'CallManager');
      }
    }
  }

  Future<void> _finalizeCurrentLog({CallLogStatus? status}) async {
    final callId = _currentCallId;
    final peerOnion = _snapshot.peerOnion;
    final direction = _currentCallDirection;
    final startedAt = _currentCallStartedAt;
    if (callId == null || peerOnion == null || direction == null || startedAt == null || _callLogFinalized) {
      return;
    }
    _callLogFinalized = true;

    final now = DateTime.now();
    final endedAt = now.millisecondsSinceEpoch;
    final activeSince = _snapshot.activeSince;
    final durationMs = activeSince != null
        ? now.difference(activeSince).inMilliseconds
        : 0;

    final resolved = status ?? _resolveFinalStatus();
    await _finalizeLog(
      callId: callId,
      peerOnion: peerOnion,
      direction: direction,
      status: resolved,
      startedAt: startedAt,
      endedAt: endedAt,
      durationMs: durationMs,
    );
  }

  CallLogStatus _resolveFinalStatus() {
    if (_snapshot.state == CallState.active) return CallLogStatus.completed;
    if (_currentCallDirection == CallLogDirection.inbound) {
      return CallLogStatus.missed;
    }
    return CallLogStatus.failed;
  }

  Future<void> _finalizeLog({
    required String callId,
    required String peerOnion,
    required CallLogDirection direction,
    required CallLogStatus status,
    required int startedAt,
    required int endedAt,
    required int durationMs,
  }) async {
    try {
      await CallLogsDb.upsertLog(
        callId: callId,
        peerOnion: peerOnion,
        direction: direction,
        status: status,
        startedAt: startedAt,
        endedAt: endedAt,
        durationMs: durationMs,
      );
      CallLogsService.instance.notifyChanged();
      unawaited(_insertCallMessage(
        peerOnion: peerOnion,
        direction: direction,
        status: status,
        endedAt: endedAt,
        durationMs: durationMs,
      ));
    } catch (e) {
      if (kDebugMode) {
        Logging.error('failed to update call log: $e', 'CallManager');
      }
    }
  }

  Future<void> _insertCallMessage({
    required String peerOnion,
    required CallLogDirection direction,
    required CallLogStatus status,
    required int endedAt,
    required int durationMs,
  }) async {
    final localOnion = LocalOnionAddress.value;
    if (localOnion == null || localOnion.isEmpty) {
      if (kDebugMode) {
        Logging.error('cannot insert call message without local onion', 'CallManager');
      }
      return;
    }

    final isOutbound = direction == CallLogDirection.outbound;
    final senderId = isOutbound ? localOnion : peerOnion;
    final receiverId = isOutbound ? peerOnion : localOnion;

    try {
      await MessagesDb.insertMessage({
        'id': const Uuid().v4(),
        'senderId': senderId,
        'receiverId': receiverId,
        'message': jsonEncode({
          'durationMs': durationMs,
          'status': status.name,
          'direction': direction.name,
        }),
        'type': 'call',
        'timestamp': endedAt,
        'status': 'system',
      });
    } catch (e) {
      if (kDebugMode) {
        Logging.error('failed to insert call message: $e', 'CallManager');
      }
    }
  }

  void _startRingTimeout(String peerOnion, String callId) {
    _ringTimer?.cancel();
    _ringTimer = Timer(const Duration(seconds: 45), () async {
      if (!_snapshot.isInCall) return;
      if (_snapshot.callId != callId) return;
      await _sendEnd(peerOnion, callId, reason: 'timeout');
      await _finalizeCurrentLog(status: CallLogStatus.missed);
      await _teardown();
      _setSnapshot(const CallSnapshot(state: CallState.idle));
    });
  }

  Future<void> _sendEnd(
    String peerOnion,
    String callId, {
    required String reason,
  }) async {
    final transport = _transport;
    if (transport == null) return;

    final payload = {'callId': callId, 'reason': reason};
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        await transport.ensureConnected(peerOnion);
        await transport.send(peerOnion, 'call_end', payload);
        return;
      } catch (e) {
        if (kDebugMode) {
          Logging.error('call_end to $peerOnion failed (attempt ${attempt + 1}): $e', 'CallManager');
        }
        if (attempt < 2) {
          await Future<void>.delayed(const Duration(milliseconds: 150));
        }
      }
    }
  }

  Future<void> _fail(String message) async {
    await _finalizeCurrentLog(status: CallLogStatus.failed);
    await _teardown();
    _setSnapshot(CallSnapshot(state: CallState.idle, error: message));
  }

  Future<void> _teardown() async {
    _ringTimer?.cancel();
    _ringTimer = null;
    await _binarySub?.cancel();
    _binarySub = null;
    await _audio?.stop();
    _audio = null;
    _session = null;
    final peer = _snapshot.peerOnion;
    if (peer != null) {
      _transport?.unpinPeer(peer);
    }
  }

  CallCodecParams _codecFromPayload(dynamic codec) {
    if (codec is! Map<String, dynamic>) {
      return const CallCodecParams();
    }
    return CallCodecParams(
      sampleRate: asInt(codec['sampleRate'], 16000),
      channels: asInt(codec['channels'], 1),
      frameDurationMs: asInt(codec['frameDurationMs'], 20),
    );
  }

  void _setSnapshot(CallSnapshot snapshot) {
    final previous = _snapshot;
    _snapshot = snapshot;
    if (_shuttingDown) return;
    unawaited(
      CallForegroundSession.instance.sync(snapshot, previous: previous),
    );
    notifyListeners();
  }

  void _shutdown() {
    _shuttingDown = true;
    final transport = _transport;
    if (transport is WsCallTransport) {
      transport.manager.onPeerDisconnected = null;
    }
    _signalSub?.cancel();
    _signalSub = null;
    unawaited(_teardown());
  }

  @override
  void dispose() {
    _shutdown();
    super.dispose();
  }
}
