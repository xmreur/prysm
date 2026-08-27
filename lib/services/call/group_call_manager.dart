import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:prysm/database/call_logs_db.dart';
import 'package:prysm/database/messages.dart';
import 'package:prysm/models/group.dart';
import 'package:prysm/server/inbound_rate_limiter.dart';
import 'package:prysm/services/block_service.dart';
import 'package:prysm/services/call/call_foreground_session.dart';
import 'package:prysm/services/call/call_logs_service.dart';
import 'package:prysm/services/call/call_manager.dart';
import 'package:prysm/services/call/call_session.dart';
import 'package:prysm/services/call/call_signaling_notifier.dart';
import 'package:prysm/services/call/call_transport.dart';
import 'package:prysm/services/call/group_audio_engine.dart';
import 'package:prysm/services/call/group_call_session.dart';
import 'package:prysm/services/call/group_call_snapshot.dart';
import 'package:prysm/services/call/opus_codec.dart';
import 'package:prysm/services/settings_service.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/util/group_moderation_policy.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/local_onion_address.dart';
import 'package:prysm/util/logging.dart';
import 'package:uuid/uuid.dart';

typedef GroupRosterLoader = Future<List<GroupCallMember>> Function(
  String groupId,
);

typedef GroupAudioFactory = GroupCallAudio Function({
  required GroupCallSession session,
  required GroupAudioSendCallback onSendFrame,
  bool Function(String peerOnion)? dropIncomingFrom,
});

/// Group audio calls as a full mesh over the per-peer Tor links.
///
/// A sibling of [CallManager] rather than a branch inside it: every 1:1
/// handler assumes a single peer, a single decoder and a single subscription.
/// The two share one device-wide occupancy slot through
/// [CallManager.extraBusyCheck].
class GroupCallManager extends ChangeNotifier {
  GroupCallManager({
    required KeyManager keyManager,
    CallTransport? transport,
    CallKeyResolver? keyResolver,
    GroupAudioFactory? audioFactory,
    SenderRefusedCallback? senderRefused,
    GroupRosterLoader? loadRoster,
    Duration ringTimeout = defaultRingTimeout,
  })  : _keyManager = keyManager,
        _transport = transport,
        _keyResolver = keyResolver,
        _audioFactory = audioFactory ?? createGroupCallAudio,
        _senderRefused = senderRefused ?? _defaultSenderRefused,
        _loadRoster = loadRoster ?? _defaultLoadRoster,
        _ringTimeout = ringTimeout;

  static GroupCallManager? _instance;

  static GroupCallManager get instance {
    final i = _instance;
    if (i == null) {
      throw StateError('GroupCallManager.configure() must be called first');
    }
    return i;
  }

  static GroupCallManager? get maybeInstance => _instance;

  static void configure({
    required KeyManager keyManager,
    CallTransport? transport,
    CallKeyResolver? keyResolver,
    GroupAudioFactory? audioFactory,
    SenderRefusedCallback? senderRefused,
    GroupRosterLoader? loadRoster,
  }) {
    final existing = _instance;
    if (existing != null && identical(existing._keyManager, keyManager)) {
      return;
    }
    existing?._shutdown();
    _instance = GroupCallManager(
      keyManager: keyManager,
      transport: transport,
      keyResolver: keyResolver,
      audioFactory: audioFactory,
      senderRefused: senderRefused,
      loadRoster: loadRoster,
    );
  }

  @visibleForTesting
  static void resetForTest() {
    _instance?._shutdown();
    _instance = null;
  }

  /// Same fixed-window flood gate as the 1:1 offer path.
  static const Duration inboundOfferWindow = Duration(seconds: 60);
  static const int maxInboundOffersPerWindow = 5;
  static const Duration defaultRingTimeout = Duration(seconds: 45);

  final KeyManager _keyManager;
  CallTransport? _transport;
  CallKeyResolver? _keyResolver;
  final GroupAudioFactory _audioFactory;
  final SenderRefusedCallback _senderRefused;
  final GroupRosterLoader _loadRoster;
  final Duration _ringTimeout;
  final InboundRateLimiter _offerLimiter = InboundRateLimiter(
    window: inboundOfferWindow,
    maxPerKey: maxInboundOffersPerWindow,
  );

  StreamSubscription<CallSignalEvent>? _signalSub;
  final Map<String, StreamSubscription<List<int>>> _binarySubs = {};
  final Set<String> _moderationMuted = {};
  GroupCallAudio? _audio;
  GroupCallSession? _session;
  Timer? _ringTimer;
  bool _shuttingDown = false;
  bool _joinInFlight = false;
  bool Function()? _busyHook;
  String? _currentCallId;
  String? _currentCallGroupId;
  CallLogDirection? _currentCallDirection;
  int? _currentCallStartedAt;
  bool _callLogFinalized = false;

  GroupCallSnapshot _snapshot = const GroupCallSnapshot(state: CallState.idle);

  GroupCallSnapshot get snapshot => _snapshot;

  bool get isBusy => _snapshot.isInCall;

  void start() {
    if (_signalSub != null) return;
    _transport ??= defaultCallTransport();
    _keyResolver ??= DbCallKeyResolver(_keyManager);
    final transport = _transport;
    if (transport is WsCallTransport) {
      // CallManager installs its own handler first; chain rather than clobber.
      final existing = transport.manager.onPeerDisconnected;
      transport.manager.onPeerDisconnected = (peer) {
        existing?.call(peer);
        handlePeerDisconnected(peer);
      };
    }
    bool busyHook() => isBusy;
    _busyHook = busyHook;
    CallManager.extraBusyCheck = busyHook;
    _signalSub = CallSignalingNotifier.active.events.listen(_onSignal);
  }

  Future<void> startGroupCall(String groupId) async {
    if (_shuttingDown || isBusy || _otherManagerBusy) return;
    final local = LocalOnionAddress.value;
    if (local == null || local.isEmpty) {
      await _fail('Local identity not ready');
      return;
    }

    final roster = await _loadRoster(groupId);
    final self = roster.where((m) => m.onion == local).firstOrNull;
    if (self == null || !canStartGroupCall(self.role)) return;

    final members = roster.map((m) => m.onion).toList(growable: false);
    _moderationMuted
      ..clear()
      ..addAll(roster.where((m) => m.muted).map((m) => m.onion));
    final listenOnly = !canSpeakInGroupCall(muted: self.muted);

    final transport = _transport!;
    final keyResolver = _keyResolver!;
    final callId = const Uuid().v4();
    final sessionId = Random.secure().nextInt(0x7fffffff);

    try {
      final session = GroupCallSession.createOutbound(
        callId: callId,
        sessionId: sessionId,
        groupId: groupId,
        members: members,
        localOnion: local,
      );
      _session = session;
      _setSnapshot(
        GroupCallSnapshot(
          state: CallState.ringing,
          groupId: groupId,
          callId: callId,
          members: members,
          joined: {local},
          localMuted: listenOnly,
          listenOnly: listenOnly,
        ),
      );
      await _startCallLog(
        callId: callId,
        groupId: groupId,
        direction: CallLogDirection.outbound,
      );
      _startRingTimeout(callId);

      final codec = {
        'sampleRate': session.codec.sampleRate,
        'channels': session.codec.channels,
        'frameDurationMs': session.codec.frameDurationMs,
      };
      for (final member in members) {
        if (member == local) continue;
        if (BlockService.instance.isBlocked(member)) continue;
        try {
          await transport.ensureConnected(member);
          final peerKey = await keyResolver.resolve(member);
          if (peerKey == null) continue;
          transport.pinPeer(member);
          await transport.send(member, 'group_call_offer', {
            'callId': callId,
            'groupId': groupId,
            'sessionId': sessionId,
            'members': members,
            'wrappedKey': await session.wrapKeyForPeer(peerKey, _keyManager),
            'codec': codec,
          });
        } catch (e) {
          // A member who is offline at offer time misses the call; the rest
          // of the fan-out must still go out.
          if (kDebugMode) {
            Logging.error(
              'group_call_offer to $member failed: $e',
              'GroupCallManager',
            );
          }
        }
      }
    } catch (e) {
      await _fail('Failed to start group call: $e');
    }
  }

  /// Accepts a ring or joins a call already in progress from the banner.
  Future<void> join() async {
    if (_shuttingDown || _joinInFlight) return;
    final session = _session;
    final groupId = _snapshot.groupId;
    final callId = _snapshot.callId;
    final local = LocalOnionAddress.value;
    if (session == null || groupId == null || callId == null || local == null) {
      return;
    }
    if (_snapshot.state == CallState.active) return;
    if (_otherManagerBusy) return;

    _joinInFlight = true;
    _ringTimer?.cancel();
    try {
      final listenOnly = _moderationMuted.contains(local) ||
          !canSpeakInGroupCall(muted: await _isMutedByModeration(groupId, local));
      _setSnapshot(
        GroupCallSnapshot(
          state: CallState.connecting,
          groupId: groupId,
          callId: callId,
          members: _snapshot.members,
          joined: {..._snapshot.joined, local},
          peerMuted: _snapshot.peerMuted,
          localMuted: _snapshot.localMuted || listenOnly,
          listenOnly: listenOnly,
        ),
      );

      final transport = _transport!;
      for (final member in _snapshot.members) {
        if (member == local) continue;
        if (BlockService.instance.isBlocked(member)) continue;
        try {
          await transport.ensureConnected(member);
          transport.pinPeer(member);
          await transport.send(member, 'group_call_join', {
            'callId': callId,
            'groupId': groupId,
          });
        } catch (e) {
          if (kDebugMode) {
            Logging.error(
              'group_call_join to $member failed: $e',
              'GroupCallManager',
            );
          }
        }
      }

      await _activateAudio(session, listenOnly: listenOnly);
    } finally {
      _joinInFlight = false;
    }
  }

  /// Stops the local ring without telling anyone: the call keeps running and
  /// the group chat banner stays so this member can still join.
  Future<void> dismissIncoming() async {
    if (_shuttingDown || _snapshot.state != CallState.incoming) return;
    _ringTimer?.cancel();
    _ringTimer = null;
    _setSnapshot(
      GroupCallSnapshot(
        state: CallState.incoming,
        groupId: _snapshot.groupId,
        callId: _snapshot.callId,
        members: _snapshot.members,
        joined: _snapshot.joined,
        peerMuted: _snapshot.peerMuted,
        listenOnly: _snapshot.listenOnly,
        dismissed: true,
      ),
    );
  }

  Future<void> leave() async {
    final callId = _snapshot.callId;
    final groupId = _snapshot.groupId;
    final local = LocalOnionAddress.value;
    if (callId != null && groupId != null && local != null) {
      await _fanoutLeave(callId, groupId, local);
    }
    await _finalizeCurrentLog();
    await _teardown();
    _setSnapshot(const GroupCallSnapshot(state: CallState.idle));
  }

  Future<void> toggleMute() async {
    if (_snapshot.listenOnly) return;
    final muted = !_snapshot.localMuted;
    _audio?.setMuted(muted);
    final callId = _snapshot.callId;
    final groupId = _snapshot.groupId;
    final local = LocalOnionAddress.value;
    if (callId != null && groupId != null) {
      for (final member in _snapshot.joined) {
        if (member == local) continue;
        try {
          await _transport?.send(member, 'group_call_mute', {
            'callId': callId,
            'groupId': groupId,
            'muted': muted,
          });
        } catch (_) {}
      }
    }
    _setSnapshot(_snapshot.copyWith(localMuted: muted));
  }

  /// Notification and tray decline for a group call.
  Future<void> declineFromNotification({
    required String callId,
    required String peerOnion,
  }) async {
    if (_shuttingDown || _snapshot.callId != callId) return;
    if (_snapshot.state == CallState.incoming && !_snapshot.dismissed) {
      await dismissIncoming();
      return;
    }
    if (_snapshot.isInCall) await leave();
  }

  /// Blocking a member mid-call drops them from the mesh.
  void onPeerBlocked(String peerOnion) {
    if (_snapshot.callId == null) return;
    if (!_snapshot.members.contains(peerOnion)) return;
    unawaited(_removeParticipant(peerOnion));
  }

  Future<void> _onSignal(CallSignalEvent event) async {
    switch (event.op) {
      case CallSignalOp.groupOffer:
        await _handleOffer(event);
      case CallSignalOp.groupJoin:
        await _handleJoin(event);
      case CallSignalOp.groupLeave:
        await _handleLeave(event);
      case CallSignalOp.groupMute:
        _handleMute(event);
      case CallSignalOp.offer:
      case CallSignalOp.answer:
      case CallSignalOp.end:
      case CallSignalOp.mute:
        break;
    }
  }

  Future<void> _handleOffer(CallSignalEvent event) async {
    if (!_offerLimiter.allow(event.peerOnion)) return;
    if (BlockService.instance.isBlocked(event.peerOnion)) return;
    if (await _senderRefused(event.peerOnion)) return;

    final payload = event.payload;
    final callId = event.callId;
    final groupId = payload['groupId'] as String?;
    final sessionId = asInt(payload['sessionId']);
    final wrappedKey = payload['wrappedKey'] as String?;
    final rawMembers = payload['members'];
    if (callId == null ||
        groupId == null ||
        sessionId == 0 ||
        wrappedKey == null ||
        rawMembers is! List) {
      return;
    }
    if (callId == _snapshot.callId) return;

    // Busy replies leave so the initiator stops waiting on us.
    if (isBusy || _otherManagerBusy) {
      await _sendLeave(event.peerOnion, callId, groupId);
      return;
    }

    final members = rawMembers.map((m) => '$m').toList(growable: false);
    final local = LocalOnionAddress.value;
    if (local == null ||
        !members.contains(local) ||
        !members.contains(event.peerOnion)) {
      return;
    }

    final roster = await _loadRoster(groupId);
    final rosterIds = roster.map((m) => m.onion).toSet();
    if (!rosterIds.contains(local) || !rosterIds.contains(event.peerOnion)) {
      return;
    }
    _moderationMuted
      ..clear()
      ..addAll(roster.where((m) => m.muted).map((m) => m.onion));

    try {
      final peerKey = await _keyResolver!.resolve(event.peerOnion);
      if (peerKey == null) {
        await _sendLeave(event.peerOnion, callId, groupId);
        return;
      }
      _session = await GroupCallSession.fromInbound(
        callId: callId,
        sessionId: sessionId,
        groupId: groupId,
        members: members,
        localOnion: local,
        wrappedKey: wrappedKey,
        keyManager: _keyManager,
        peer: peerKey,
        codec: _codecFromPayload(payload['codec']),
      );
      _transport?.pinPeer(event.peerOnion);
      _setSnapshot(
        GroupCallSnapshot(
          state: CallState.incoming,
          groupId: groupId,
          callId: callId,
          members: members,
          joined: {event.peerOnion},
          listenOnly: _moderationMuted.contains(local),
        ),
      );
      await _startCallLog(
        callId: callId,
        groupId: groupId,
        direction: CallLogDirection.inbound,
      );
      _startRingTimeout(callId);
    } catch (e) {
      _session = null;
      await _sendLeave(event.peerOnion, callId, groupId);
    }
  }

  Future<void> _handleJoin(CallSignalEvent event) async {
    if (event.callId == null || event.callId != _snapshot.callId) return;
    if (!_snapshot.members.contains(event.peerOnion)) return;
    if (BlockService.instance.isBlocked(event.peerOnion)) return;

    final ringingOut = _snapshot.state == CallState.ringing;
    _setSnapshot(
      _snapshot.copyWith(
        state: ringingOut ? CallState.connecting : _snapshot.state,
        joined: {..._snapshot.joined, event.peerOnion},
      ),
    );

    final session = _session;
    if (ringingOut && session != null) {
      _ringTimer?.cancel();
      await _activateAudio(session, listenOnly: _snapshot.listenOnly);
      return;
    }
    _subscribePeer(event.peerOnion);
    _audio?.addRemote(event.peerOnion);
    _syncSendTargets();
  }

  Future<void> _handleLeave(CallSignalEvent event) async {
    if (event.callId == null || event.callId != _snapshot.callId) return;
    if (!_snapshot.members.contains(event.peerOnion)) return;
    await _removeParticipant(event.peerOnion);
  }

  /// A leave from a peer that never joined is a busy or blocked reply — it
  /// must not end a call the others are still in.
  Future<void> _removeParticipant(String peerOnion) async {
    final local = LocalOnionAddress.value;
    final hadRemote = _snapshot.joined.any((m) => m != local);
    final joined = {..._snapshot.joined}..remove(peerOnion);
    _unsubscribePeer(peerOnion);
    _audio?.removeRemote(peerOnion);
    _transport?.unpinPeer(peerOnion);
    _setSnapshot(
      _snapshot.copyWith(
        joined: joined,
        peerMuted: {..._snapshot.peerMuted}..remove(peerOnion),
      ),
    );
    _syncSendTargets();

    if (!hadRemote) return;
    if (joined.any((m) => m != local)) return;
    if (_snapshot.callId == null) return;
    await _finalizeCurrentLog();
    await _teardown();
    _setSnapshot(const GroupCallSnapshot(state: CallState.idle));
  }

  void _handleMute(CallSignalEvent event) {
    if (event.callId == null || event.callId != _snapshot.callId) return;
    if (!_snapshot.members.contains(event.peerOnion)) return;
    _setSnapshot(
      _snapshot.copyWith(
        peerMuted: {
          ..._snapshot.peerMuted,
          event.peerOnion: event.payload['muted'] == true,
        },
      ),
    );
  }

  Future<void> _activateAudio(
    GroupCallSession session, {
    required bool listenOnly,
  }) async {
    if (_shuttingDown) return;
    final transport = _transport!;
    final audio = _audioFactory(
      session: session,
      onSendFrame: (peer, frame) {
        unawaited(
          transport.sendBytes(peer, frame).catchError((Object e) {
            if (kDebugMode) {
              Logging.error(
                'group sendBytes to $peer failed: $e',
                'GroupCallManager',
              );
            }
          }),
        );
      },
      dropIncomingFrom: _dropIncomingFrom,
    );
    _audio = audio;
    audio.setMuted(_snapshot.localMuted || listenOnly);

    final local = session.localOnion;
    for (final peer in _snapshot.joined) {
      if (peer == local) continue;
      audio.addRemote(peer);
      _subscribePeer(peer);
    }
    _syncSendTargets();

    final started = await audio.start(listenOnly: listenOnly);
    if (!started) {
      await _fail(
        GroupAudioEngine.lastStartError ??
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
      _snapshot.copyWith(
        state: CallState.active,
        localMuted: _snapshot.localMuted || listenOnly,
        listenOnly: listenOnly,
        activeSince: DateTime.now(),
      ),
    );
  }

  /// Moderation mute is enforced on both sides: a muted member joins with
  /// capture off, and every other participant drops its audio anyway.
  bool _dropIncomingFrom(String peerOnion) =>
      _moderationMuted.contains(peerOnion) ||
      BlockService.instance.isBlocked(peerOnion);

  void _subscribePeer(String peerOnion) {
    if (_binarySubs.containsKey(peerOnion)) return;
    final transport = _transport;
    if (transport == null) return;
    _binarySubs[peerOnion] =
        transport.binaryFramesFor(peerOnion).listen((bytes) {
      _audio?.handleIncoming(peerOnion, Uint8List.fromList(bytes));
    });
  }

  void _unsubscribePeer(String peerOnion) {
    unawaited(_binarySubs.remove(peerOnion)?.cancel());
  }

  void _syncSendTargets() {
    final local = LocalOnionAddress.value;
    _audio?.setSendTargets(
      _snapshot.joined
          .where((m) => m != local && !BlockService.instance.isBlocked(m))
          .toSet(),
    );
  }

  /// A dropped link is a leave; a rejoin resubscribes.
  @visibleForTesting
  void handlePeerDisconnected(String peerOnion) {
    if (_snapshot.callId == null) return;
    if (!_snapshot.joined.contains(peerOnion)) return;
    unawaited(_removeParticipant(peerOnion));
  }

  Future<void> _sendLeave(
    String peerOnion,
    String callId,
    String groupId,
  ) async {
    try {
      await _transport?.send(peerOnion, 'group_call_leave', {
        'callId': callId,
        'groupId': groupId,
      });
    } catch (_) {}
  }

  Future<void> _fanoutLeave(
    String callId,
    String groupId,
    String local,
  ) async {
    for (final member in _snapshot.members) {
      if (member == local) continue;
      try {
        await _transport?.ensureConnected(member);
      } catch (_) {}
      await _sendLeave(member, callId, groupId);
    }
  }

  /// Nobody joined in time. The initiator gives up; a rung member stops
  /// ringing but keeps the banner so it can still join later.
  void _startRingTimeout(String callId) {
    _ringTimer?.cancel();
    _ringTimer = Timer(_ringTimeout, () async {
      if (_snapshot.callId != callId) return;
      final local = LocalOnionAddress.value;
      if (_snapshot.joined.any((m) => m != local)) return;
      if (_snapshot.state == CallState.incoming) {
        await dismissIncoming();
        return;
      }
      final groupId = _snapshot.groupId;
      if (groupId != null && local != null) {
        await _fanoutLeave(callId, groupId, local);
      }
      await _finalizeCurrentLog(status: CallLogStatus.missed);
      await _teardown();
      _setSnapshot(const GroupCallSnapshot(state: CallState.idle));
    });
  }

  Future<void> _startCallLog({
    required String callId,
    required String groupId,
    required CallLogDirection direction,
  }) async {
    _currentCallId = callId;
    _currentCallGroupId = groupId;
    _currentCallDirection = direction;
    _currentCallStartedAt = DateTime.now().millisecondsSinceEpoch;
    _callLogFinalized = false;
    try {
      await CallLogsDb.insertLog(
        callId: callId,
        peerOnion: groupId,
        direction: direction,
        status: CallLogStatus.ringing,
        startedAt: _currentCallStartedAt!,
        groupId: groupId,
      );
      CallLogsService.instance.notifyChanged();
    } catch (e) {
      if (kDebugMode) {
        Logging.error(
          'failed to insert group call log: $e',
          'GroupCallManager',
        );
      }
    }
  }

  Future<void> _finalizeCurrentLog({CallLogStatus? status}) async {
    final callId = _currentCallId;
    final groupId = _currentCallGroupId;
    final direction = _currentCallDirection;
    final startedAt = _currentCallStartedAt;
    if (callId == null ||
        groupId == null ||
        direction == null ||
        startedAt == null ||
        _callLogFinalized) {
      return;
    }
    _callLogFinalized = true;

    final now = DateTime.now();
    final activeSince = _snapshot.activeSince;
    final durationMs =
        activeSince != null ? now.difference(activeSince).inMilliseconds : 0;
    final resolved = status ??
        (_snapshot.state == CallState.active
            ? CallLogStatus.completed
            : direction == CallLogDirection.inbound
                ? CallLogStatus.missed
                : CallLogStatus.failed);

    try {
      await CallLogsDb.upsertLog(
        callId: callId,
        peerOnion: groupId,
        direction: direction,
        status: resolved,
        startedAt: startedAt,
        endedAt: now.millisecondsSinceEpoch,
        durationMs: durationMs,
        groupId: groupId,
      );
      CallLogsService.instance.notifyChanged();
      unawaited(
        _insertCallMessage(
          groupId: groupId,
          direction: direction,
          status: resolved,
          endedAt: now.millisecondsSinceEpoch,
          durationMs: durationMs,
        ),
      );
    } catch (e) {
      if (kDebugMode) {
        Logging.error(
          'failed to update group call log: $e',
          'GroupCallManager',
        );
      }
    }
  }

  Future<void> _insertCallMessage({
    required String groupId,
    required CallLogDirection direction,
    required CallLogStatus status,
    required int endedAt,
    required int durationMs,
  }) async {
    final localOnion = LocalOnionAddress.value;
    if (localOnion == null || localOnion.isEmpty) return;
    try {
      await MessagesDb.insertMessage({
        'id': const Uuid().v4(),
        'senderId': localOnion,
        'receiverId': groupId,
        'groupId': groupId,
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
        Logging.error(
          'failed to insert group call message: $e',
          'GroupCallManager',
        );
      }
    }
  }

  bool get _otherManagerBusy => CallManager.maybeInstance?.isBusy ?? false;

  Future<bool> _isMutedByModeration(String groupId, String onion) async {
    try {
      final roster = await _loadRoster(groupId);
      _moderationMuted
        ..clear()
        ..addAll(roster.where((m) => m.muted).map((m) => m.onion));
      return _moderationMuted.contains(onion);
    } catch (_) {
      return _moderationMuted.contains(onion);
    }
  }

  Future<void> _fail(String message) async {
    await _finalizeCurrentLog(status: CallLogStatus.failed);
    await _teardown();
    _setSnapshot(GroupCallSnapshot(state: CallState.idle, error: message));
  }

  Future<void> _teardown() async {
    _ringTimer?.cancel();
    _ringTimer = null;
    for (final sub in _binarySubs.values) {
      await sub.cancel();
    }
    _binarySubs.clear();
    await _audio?.stop();
    _audio = null;
    _session = null;
    _moderationMuted.clear();
    final local = LocalOnionAddress.value;
    for (final member in _snapshot.members) {
      if (member != local) _transport?.unpinPeer(member);
    }
  }

  CallCodecParams _codecFromPayload(dynamic codec) {
    if (codec is! Map<String, dynamic>) return const CallCodecParams();
    return CallCodecParams(
      sampleRate: asInt(codec['sampleRate'], 16000),
      channels: asInt(codec['channels'], 1),
      frameDurationMs: asInt(codec['frameDurationMs'], 20),
    );
  }

  void _setSnapshot(GroupCallSnapshot snapshot) {
    final previous = _snapshot;
    _snapshot = snapshot;
    if (_shuttingDown) return;
    unawaited(
      CallForegroundSession.instance.sync(
        snapshot.asCallSnapshot,
        previous: previous.asCallSnapshot,
      ),
    );
    notifyListeners();
  }

  void _shutdown() {
    _shuttingDown = true;
    if (identical(CallManager.extraBusyCheck, _busyHook)) {
      CallManager.extraBusyCheck = null;
    }
    _busyHook = null;
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

Future<bool> _defaultSenderRefused(String peerOnion) async {
  if (!SettingsService().refuseUnknownSenders) return false;
  return (await DBHelper.getUserById(peerOnion)) == null;
}

Future<List<GroupCallMember>> _defaultLoadRoster(String groupId) async {
  final rows = await DBHelper.getGroupMembers(groupId);
  return rows
      .map(
        (row) => GroupCallMember(
          onion: row['memberId'] as String,
          role: groupRoleFromWire(row['role'] as String?),
          muted: (row['muted'] ?? 0) == 1,
        ),
      )
      .toList(growable: false);
}
