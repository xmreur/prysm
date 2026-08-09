import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:prysm/client/tor_websocket_client.dart';
import 'package:prysm/database/messages.dart';
import 'package:prysm/services/call/call_signaling_notifier.dart';
import 'package:prysm/services/file_transfer_handler.dart';
import 'package:prysm/services/ws_inbound_dispatcher.dart';
import 'package:prysm/transport/inbound_ws_peer_link.dart';
import 'package:prysm/transport/outbound_ws_peer_link.dart';
import 'package:prysm/transport/peer_transport_registry.dart';
import 'package:prysm/transport/ws_dial_policy.dart';
import 'package:prysm/transport/ws_peer_link.dart';
import 'package:prysm/transport/ws_protocol.dart';
import 'package:prysm/util/battery_saver_policy.dart';
import 'package:prysm/util/logging.dart';
import 'package:prysm/util/peer_ws_connection_notifier.dart';
import 'package:prysm/util/tor_delivery.dart';
import 'package:prysm/util/tor_runtime_gate.dart';
import 'package:prysm/util/tor_service.dart';

/// Thrown by [WsConnectionManager.ensureConnected] when the peer is already in
/// reconnect backoff. The attempt never reached the wire, so it is not a fresh
/// connect failure: callers must not record it or re-arm the backoff window.
class PeerInBackoffError extends StateError {
  PeerInBackoffError() : super('Peer reconnect backoff active');
}

/// Maintains one full-duplex WebSocket link per peer (dialer or acceptor).
class WsConnectionManager {
  WsConnectionManager(this._torManager);

  static const Duration interactiveConnectBudget = Duration(seconds: 25);

  static const Duration backgroundConnectTimeout = Duration(seconds: 30);
  static const Duration _maxReconnectBackoff = Duration(minutes: 2);
  static const int _maxPingFailures = 3;

  /// Consecutive real dial failures after which a peer is quarantined: its
  /// retry cadence drops from the ~2 min backoff cap to
  /// [hostUnreachableQuarantine] until it proves reachable again (inbound
  /// contact, authenticated wake hint, or explicit user action).
  ///
  /// A failure counts when it falls in the dial path's own retry taxonomy
  /// ([TorDelivery.isRetryableError]) — `hostUnreachable` SOCKS replies,
  /// connect timeouts, and the other peer-reachability failures the device
  /// log shows for dead peers. Local state errors (no local onion, Tor
  /// stopped) never count.
  static const int hostUnreachableQuarantineThreshold = 10;
  static const Duration hostUnreachableQuarantine = Duration(minutes: 10);

  final TorManager _torManager;
  final Map<String, WsPeerLink> _links = {};
  final Map<String, Future<void>> _connectChains = {};
  final Map<String, Future<void>> _requestChains = {};
  final Map<String, int> _requestQueueDepthByPeer = {};
  final Map<String, int> _connectFailures = {};
  final Map<String, int> _hostUnreachableStreak = {};
  final Map<String, DateTime> _quarantineUntil = {};
  final Map<String, int> _pingFailures = {};
  final Map<String, DateTime> _lastSuccessByPeer = {};
  final Map<String, DateTime> _nextRetryAfter = {};
  final Map<String, List<Completer<void>>> _inboundWaiters = {};
  final Set<String> _connectingPeers = {};
  final Set<String> _pinnedPeers = {};
  final Map<String, Set<String>> _peerSupports = {};
  String? _localOnion;
  Timer? _maintainTimer;
  bool _running = false;
  bool _disposed = false;

  int outboundQueueDepth = 0;

  Future<bool> Function(String peerId)? onPeerConnected;
  void Function(String peerOnion)? onPeerDisconnected;
  Future<void> Function(String peerOnion)? nudgePeerForInbound;

  DateTime? lastSuccessForPeer(String peerOnion) =>
      _lastSuccessByPeer[peerOnion];

  bool isConnected(String peerOnion) =>
      _links[peerOnion]?.isConnected ?? false;

  bool isConnectInFlight(String peerOnion) => _connectingPeers.contains(peerOnion);

  bool hasLink(String peerOnion) => _links.containsKey(peerOnion);

  bool peerSupports(String peerOnion, String capability) =>
      _peerSupports[peerOnion]?.contains(capability) ?? false;

  bool peerSupportsFileTransfer(String peerOnion) =>
      peerSupports(peerOnion, wsFileTransferCapability);

  Stream<Map<String, dynamic>> pushFramesFor(String peerOnion) {
    final link = _links[peerOnion];
    if (link == null) {
      return const Stream<Map<String, dynamic>>.empty();
    }
    return link.onPushFrames;
  }

  void pinPeer(String peerOnion) {
    // Opening a chat, calling, or transferring is an explicit user action:
    // lift any backoff/quarantine so the fresh attempt is not rate-limited.
    clearPeerFailureState(peerOnion);
    _pinnedPeers.add(peerOnion);
  }

  void unpinPeer(String peerOnion) => _pinnedPeers.remove(peerOnion);

  static const Duration _warmDebounce = Duration(seconds: 45);
  final Map<String, DateTime> _lastWarmAttempt = {};

  void warmPeer(String peerOnion) {
    if (_disposed || !_running || TorRuntimeGate.blocked) return;
    if (isConnected(peerOnion) || isConnectInFlight(peerOnion)) return;

    final last = _lastWarmAttempt[peerOnion];
    if (!_pinnedPeers.contains(peerOnion) &&
        last != null &&
        DateTime.now().difference(last) < _warmDebounce) {
      return;
    }
    _lastWarmAttempt[peerOnion] = DateTime.now();

    unawaited(
      ensureConnected(
        peerOnion,
        connectBudget: interactiveConnectBudget,
      ).catchError((_) {}),
    );
  }

  void start() {
    if (_disposed || _running) return;
    _running = true;
    unawaited(_maintainOnceAndReschedule());
  }

  Future<void> _maintainOnceAndReschedule() async {
    if (!_running || _disposed) return;
    await _maintainConnections();
    if (_running && !_disposed) {
      _scheduleMaintain();
    }
  }

  void stop() {
    _running = false;
    _maintainTimer?.cancel();
    _maintainTimer = null;
    for (final peer in _links.keys.toList()) {
      unawaited(_removeLink(peer));
    }
    _links.clear();
    _connectChains.clear();
    _nextRetryAfter.clear();
    _connectingPeers.clear();
    for (final waiters in _inboundWaiters.values) {
      for (final waiter in waiters) {
        if (!waiter.isCompleted) {
          waiter.completeError(StateError('WsConnectionManager stopped'));
        }
      }
    }
    _inboundWaiters.clear();
  }

  void _scheduleMaintain() {
    _maintainTimer?.cancel();
    _maintainTimer = Timer(wsHeartbeatInterval(), () async {
      if (!_running || _disposed) return;
      await _maintainConnections();
      if (_running && !_disposed) {
        _scheduleMaintain();
      }
    });
  }

  static Duration wsHeartbeatInterval([bool? saving]) =>
      BatterySaverPolicy.wsHeartbeatInterval(saving);

  Future<void> _maintainConnections() async {
    if (TorRuntimeGate.blocked) return;

    final targets = await _connectionTargets();
    final localOnion = await _resolveLocalOnion();

    for (final peer in targets) {
      if (_isInBackoff(peer)) continue;

      if (_links[peer]?.isConnected == true) {
        if (isConnectInFlight(peer)) continue;
        try {
          await _links[peer]!.sendPing();
          _pingFailures.remove(peer);
        } catch (_) {
          final failures = (_pingFailures[peer] ?? 0) + 1;
          _pingFailures[peer] = failures;
          if (failures >= _maxPingFailures && !_pinnedPeers.contains(peer)) {
            _pingFailures.remove(peer);
            await _removeLink(peer);
          }
        }
        continue;
      }

      if (isConnectInFlight(peer)) continue;

      if (localOnion == null || localOnion.isEmpty) continue;

      if (!shouldDialPeer(localOnion: localOnion, peerOnion: peer)) {
        continue;
      }

      try {
        await ensureConnected(peer);
        _connectFailures.remove(peer);
        _nextRetryAfter.remove(peer);
      } catch (e) {
        // A fast-fail because the peer is already in backoff never reached
        // the wire: it must not count as a fresh failure or re-arm the window.
        if (e is PeerInBackoffError) continue;
        _recordConnectFailure(peer, e);
      }
    }

    final stale = _links.keys
        .where((peer) => !targets.contains(peer) && !_pinnedPeers.contains(peer))
        .toList();
    for (final peer in stale) {
      await _removeLink(peer);
    }
  }

  bool _isInBackoff(String peerOnion) {
    final retryAfter = _nextRetryAfter[peerOnion];
    if (retryAfter == null) return false;
    return DateTime.now().isBefore(retryAfter);
  }

  void _recordConnectFailure(String peerOnion, Object error) {
    final failures = (_connectFailures[peerOnion] ?? 0) + 1;
    _connectFailures[peerOnion] = failures;

    final backoffSeconds = failures <= 6 ? (1 << (failures - 1)) : 120;
    final backoff = Duration(
      seconds: backoffSeconds.clamp(1, _maxReconnectBackoff.inSeconds),
    );
    _nextRetryAfter[peerOnion] = DateTime.now().add(backoff);

    if (_isPeerUnreachableError(error)) {
      final streak = (_hostUnreachableStreak[peerOnion] ?? 0) + 1;
      _hostUnreachableStreak[peerOnion] = streak;
      if (streak >= hostUnreachableQuarantineThreshold &&
          !_isQuarantined(peerOnion)) {
        // Overrides the regular backoff with the longer quarantine window.
        _enterQuarantine(peerOnion);
      }
    } else {
      // A local or protocol failure (no local onion, Tor stopped) breaks the
      // peer-unreachable streak.
      _hostUnreachableStreak.remove(peerOnion);
    }
  }

  /// True when [error] indicates the peer did not answer a real dial attempt
  /// — the peer-reachability class the dial path itself retries
  /// ([TorDelivery.isRetryableError]). A local state error (e.g. no local
  /// onion address) is not the peer's fault and never counts.
  bool _isPeerUnreachableError(Object error) =>
      TorDelivery.isRetryableError(error);

  bool _isQuarantined(String peerOnion) {
    final until = _quarantineUntil[peerOnion];
    if (until == null) return false;
    if (DateTime.now().isBefore(until)) return true;
    _quarantineUntil.remove(peerOnion);
    return false;
  }

  void _enterQuarantine(String peerOnion) {
    final until = DateTime.now().add(hostUnreachableQuarantine);
    _quarantineUntil[peerOnion] = until;
    _nextRetryAfter[peerOnion] = until;
    Logging.debug(
      'Quarantining ${Logging.redactOnion(peerOnion)} after '
      '$hostUnreachableQuarantineThreshold consecutive unreachable dial failures',
      'WsConnectionManager',
    );
  }

  /// Minimum remaining backoff window before a peer counts as genuinely,
  /// repeatedly unreachable for wake-hint suppression. The backoff ladder
  /// (1, 2, 4, 8, 16, 32 s, then the 120 s cap) only reaches this at the
  /// seventh consecutive failure, so a single transient blip never silences
  /// hints, while a peer in the capped dead-peer regime — and the 10-minute
  /// quarantine, which is a 10-minute window — is left alone.
  static const Duration _wakeHintUnreachableMinBackoff = Duration(seconds: 60);

  /// True when [peerOnion] is in reconnect backoff with a window long enough
  /// to indicate sustained, repeated unreachability — wake hints to such peers
  /// only feed the failure storm. A single transient failure (short window)
  /// must not suppress hints: the hint is the nudge that wakes a sleeping
  /// peer.
  bool isPeerUnreachable(String peerOnion) {
    final retryAfter = _nextRetryAfter[peerOnion];
    if (retryAfter == null) return false;
    return retryAfter.difference(DateTime.now()) >=
        _wakeHintUnreachableMinBackoff;
  }

  /// Resets throttling state for [peerOnion] because it proved reachable
  /// (inbound contact, authenticated wake hint) or the user explicitly
  /// engaged with it, so the next connect attempt is not rate-limited.
  void clearPeerFailureState(String peerOnion) {
    _connectFailures.remove(peerOnion);
    _nextRetryAfter.remove(peerOnion);
    _hostUnreachableStreak.remove(peerOnion);
    _quarantineUntil.remove(peerOnion);
  }

  void prepareForTorReconnect() {
    _connectFailures.clear();
    _nextRetryAfter.clear();
    _hostUnreachableStreak.clear();
    _quarantineUntil.clear();
    _localOnion = null;
    for (final peer in _links.keys.toList()) {
      unawaited(_removeLink(peer));
    }
    if (_running && !_disposed) {
      unawaited(_maintainConnections());
    }
  }

  Future<Set<String>> _connectionTargets() async {
    try {
      final timestamps = await MessagesDb.getLastMessageTimestampsForAllUsers();
      final recent = timestamps.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      final targets = recent
          .take(BatterySaverPolicy.wakeHintMaxPeers)
          .map((e) => e.key)
          .toSet();
      targets.addAll(_pinnedPeers);

      final localOnion = await _resolveLocalOnion();
      if (localOnion != null && localOnion.isNotEmpty) {
        targets.remove(localOnion);
      }

      return targets;
    } catch (e) {
      Logging.error('DB not ready for peer targets: $e', 'WsConnectionManager');
      
      return Set<String>.from(_pinnedPeers);
    }
  }

  Future<void> ensureConnected(
    String peerOnion, {
    Duration? connectBudget,
  }) {
    if (_disposed || TorRuntimeGate.blocked) {
      return Future.error(StateError('Cannot connect while Tor is stopped'));
    }
    if (_links[peerOnion]?.isConnected == true) {
      return Future<void>.value();
    }
    if (_isInBackoff(peerOnion)) {
      // Respect backoff on every path: a user-initiated connect against a
      // throttled peer fails fast so callers fall back to the HTTP path
      // instead of blocking the UI for the interactive connect budget.
      return Future.error(PeerInBackoffError());
    }

    final prev = _connectChains[peerOnion] ?? Future<void>.value();
    late final Future<void> chained;
    chained = prev.then(
      (_) => _ensureLinkOnce(
        peerOnion,
        connectTimeout: connectBudget ?? backgroundConnectTimeout,
        useTorRetry: connectBudget == null,
      ),
    );
    _connectChains[peerOnion] =
        chained.then((_) {}, onError: (_) {});
    return chained;
  }

  Future<void> _ensureLinkOnce(
    String peerOnion, {
    required Duration connectTimeout,
    required bool useTorRetry,
  }) async {
    if (_links[peerOnion]?.isConnected == true) return;
    if (isConnectInFlight(peerOnion)) return;

    final localOnion = await _resolveLocalOnion();
    if (localOnion == null || localOnion.isEmpty) {
      throw StateError('Local onion address not available');
    }

    if (shouldDialPeer(localOnion: localOnion, peerOnion: peerOnion)) {
      await _ensureOutboundLink(
        peerOnion,
        connectTimeout: connectTimeout,
        useTorRetry: useTorRetry,
      );
      return;
    }

    await _waitForInboundLink(peerOnion, timeout: connectTimeout);
  }

  Future<void> _nudgeInboundDialer(String peerOnion) async {
    final nudge = nudgePeerForInbound;
    if (nudge == null) return;
    try {
      await nudge(peerOnion);
    } catch (_) {}
  }

  Future<void> _ensureOutboundLink(
    String peerOnion, {
    required Duration connectTimeout,
    required bool useTorRetry,
  }) async {
    final existing = _links[peerOnion];
    if (existing != null) {
      await _removeLink(peerOnion);
    }

    _connectingPeers.add(peerOnion);
    try {
      Future<void> connectOnce() async {
        final localOnion = await _resolveLocalOnion();
        final client = TorWebSocketClient(
          peerOnion: peerOnion,
          socksPort: _torManager.socksPort,
          localOnion: localOnion,
          onBinaryFrame: (raw, sendAck) =>
              _dispatchBinaryFrame(raw, peerOnion, sendAck),
          onTextFrame: (frame) => _dispatchTextFrame(frame, peerOnion),
        );
        await client.connect(timeout: connectTimeout);
        final link = OutboundWsPeerLink(client);
        _registerLink(peerOnion, link, outbound: true);
        if (kDebugMode) {
          Logging.debug('connected to $peerOnion', 'WsConnectionManager');
        }
      }

      if (useTorRetry) {
        await TorDelivery.withTorRetry<void>(attempt: connectOnce);
      } else {
        await connectOnce();
      }
    } catch (e, stack) {
      if (kDebugMode) {
        Logging.error('connect to $peerOnion failed: $e', 'WsConnectionManager');
        if (!useTorRetry) {
          Logging.error('$stack', 'WsConnectionManager');
        }
      }
      rethrow;
    } finally {
      _connectingPeers.remove(peerOnion);
    }
  }

  bool _dispatchBinaryFrame(
    List<int> raw,
    String peerOnion,
    Future<void> Function(String op, {Map<String, dynamic>? payload}) sendAck,
  ) {
    if (raw.isNotEmpty && raw[0] == fileTransferChunkMagic) {
      unawaited(
        FileTransferHandler.instance.handleBinaryChunk(
          raw,
          peerOnion: peerOnion,
          sendAck: sendAck,
        ),
      );
      return true;
    }
    return false;
  }

  bool _dispatchTextFrame(
    Map<String, dynamic> frame,
    String peerOnion,
  ) {
    final op = frame['op'];
    if (op is String && WsFrame.isCallOp(op)) {
      final payload = frame['payload'];
      if (payload is Map<String, dynamic>) {
        CallSignalingNotifier.active.applyInbound(peerOnion, op, payload);
      }
      return true;
    }
    return false;
  }

  Future<void> _waitForInboundLink(
    String peerOnion, {
    required Duration timeout,
  }) async {
    if (_links[peerOnion]?.isConnected == true) return;

    unawaited(_nudgeInboundDialer(peerOnion));

    final completer = Completer<void>();
    _inboundWaiters.putIfAbsent(peerOnion, () => []).add(completer);

    try {
      await completer.future.timeout(timeout);
    } on TimeoutException {
      throw StateError('Timed out waiting for inbound WebSocket from $peerOnion');
    } finally {
      _inboundWaiters[peerOnion]?.remove(completer);
      if (_inboundWaiters[peerOnion]?.isEmpty ?? false) {
        _inboundWaiters.remove(peerOnion);
      }
    }
  }

  /// Registers an inbound acceptor link from [PrysmServer].
  void registerInboundLink(InboundWsPeerLink link) {
    final peerOnion = link.peerOnion;
    final existing = _links[peerOnion];
    if (existing != null && existing.isConnected) {
      unawaited(link.rejectDuplicateConnection());
      return;
    }
    if (existing != null) {
      unawaited(_removeLink(peerOnion));
    }
    _registerLink(peerOnion, link, outbound: false);
    if (kDebugMode) {
      Logging.debug('accepted from $peerOnion', 'WsConnectionManager');
    }
  }

  void _registerLink(
    String peerOnion,
    WsPeerLink link, {
    required bool outbound,
  }) {
    _links[peerOnion] = link;
    _recordPeerSupports(peerOnion, link);
    WsInboundDispatcher.instance.attach(peerOnion, link.onPushFrames);
    PeerTransportRegistry.instance.markWebSocket(peerOnion);
    _connectFailures.remove(peerOnion);
    _nextRetryAfter.remove(peerOnion);
    _hostUnreachableStreak.remove(peerOnion);
    _quarantineUntil.remove(peerOnion);
    _pingFailures.remove(peerOnion);
    _lastSuccessByPeer[peerOnion] = DateTime.now();

    final waiters = _inboundWaiters.remove(peerOnion);
    if (waiters != null) {
      for (final waiter in waiters) {
        if (!waiter.isCompleted) {
          waiter.complete();
        }
      }
    }

    final flush = onPeerConnected;
    if (flush != null) {
      unawaited(flush(peerOnion));
    }

    PeerWsConnectionNotifier.instance.notify(peerOnion, connected: true);
  }

  void unregisterLink(String peerOnion) {
    unawaited(_removeLink(peerOnion));
  }

  Future<String?> _resolveLocalOnion() async {
    if (_localOnion != null && _localOnion!.isNotEmpty) {
      return _localOnion;
    }
    try {
      _localOnion = await _torManager.getOnionAddress();
    } catch (_) {}
    return _localOnion;
  }

  Future<Map<String, dynamic>> request(
    String peerOnion,
    String op, {
    Map<String, dynamic>? payload,
    Duration timeout = const Duration(seconds: 30),
    bool bypassQueue = false,
  }) {
    Future<Map<String, dynamic>> operation() async {
      if (TorRuntimeGate.blocked) {
        throw StateError('Tor is stopped');
      }
      final link = _links[peerOnion];
      if (link == null || !link.isConnected) {
        throw StateError('WebSocket not connected to $peerOnion');
      }
      final result =
          await link.request(op, payload: payload, timeout: timeout);
      _lastSuccessByPeer[peerOnion] = DateTime.now();
      _pingFailures.remove(peerOnion);
      return result;
    }

    if (bypassQueue) {
      return operation();
    }

    return _enqueueRequest(peerOnion, operation);
  }

  /// Ensures a WS link exists before a large upload.
  Future<void> prepareForFileTransfer(String peerOnion) async {
    if (_disposed || TorRuntimeGate.blocked) {
      throw StateError('Tor is stopped');
    }
    pinPeer(peerOnion);

    if (isConnected(peerOnion)) return;

    await ensureConnected(
      peerOnion,
      connectBudget: interactiveConnectBudget,
    );

    if (!isConnected(peerOnion)) {
      throw StateError('WebSocket not connected to $peerOnion');
    }
  }

  Future<void> send(
    String peerOnion,
    String op, {
    Map<String, dynamic>? payload,
  }) async {
    if (TorRuntimeGate.blocked) {
      throw StateError('Tor is stopped');
    }
    outboundQueueDepth++;
    try {
      final link = _links[peerOnion];
      if (link == null || !link.isConnected) {
        throw StateError('WebSocket not connected to $peerOnion');
      }
      await link.send(op, payload: payload);
      _lastSuccessByPeer[peerOnion] = DateTime.now();
      _pingFailures.remove(peerOnion);
    } finally {
      outboundQueueDepth--;
    }
  }

  Future<void> sendBytes(String peerOnion, List<int> bytes) async {
    if (TorRuntimeGate.blocked) {
      throw StateError('Tor is stopped');
    }
    outboundQueueDepth++;
    try {
      final link = _links[peerOnion];
      if (link == null || !link.isConnected) {
        throw StateError('WebSocket not connected to $peerOnion');
      }
      await link.sendBytes(bytes);
      _lastSuccessByPeer[peerOnion] = DateTime.now();
      _pingFailures.remove(peerOnion);
    } finally {
      outboundQueueDepth--;
    }
  }

  Stream<List<int>> binaryFramesFor(String peerOnion) {
    final link = _links[peerOnion];
    if (link == null) {
      return const Stream<List<int>>.empty();
    }
    return link.onBinaryFrames;
  }

  Future<T> _enqueueRequest<T>(
    String peerOnion,
    Future<T> Function() operation,
  ) {
    final prev = _requestChains[peerOnion] ?? Future<void>.value();
    late final Future<T> chained;
    chained = prev.then((_) => operation());
    _requestChains[peerOnion] =
        chained.then((_) {}, onError: (_) {});
    _requestQueueDepthByPeer[peerOnion] =
        (_requestQueueDepthByPeer[peerOnion] ?? 0) + 1;
    outboundQueueDepth++;
    return chained.whenComplete(() {
      outboundQueueDepth--;
      final remaining = (_requestQueueDepthByPeer[peerOnion] ?? 1) - 1;
      if (remaining <= 0) {
        _requestQueueDepthByPeer.remove(peerOnion);
      } else {
        _requestQueueDepthByPeer[peerOnion] = remaining;
      }
    });
  }

  Future<T> runForPeer<T>(String peerOnion, Future<T> Function() operation) =>
      operation();

  void _recordPeerSupports(String peerOnion, WsPeerLink link) {
    if (link is OutboundWsPeerLink) {
      _peerSupports[peerOnion] = link.client.peerSupports.toSet();
      return;
    }
    if (link is InboundWsPeerLink) {
      _peerSupports[peerOnion] = link.peerSupports.toSet();
    }
  }

  Future<void> disconnectPeer(String peerOnion) => _removeLink(peerOnion);

  Future<void> _removeLink(String peerOnion) async {
    final link = _links.remove(peerOnion);
    if (link == null) return;

    final wasPinned = _pinnedPeers.contains(peerOnion);
    _peerSupports.remove(peerOnion);

    WsInboundDispatcher.instance.detach(peerOnion);
    await link.close();
    onPeerDisconnected?.call(peerOnion);
    PeerWsConnectionNotifier.instance.notify(peerOnion, connected: false);

    if (wasPinned && _running && !_disposed) {
      unawaited(_reconnectPinnedPeer(peerOnion));
    }
  }

  Future<void> _reconnectPinnedPeer(String peerOnion) async {
    await Future<void>.delayed(const Duration(seconds: 1));
    if (_links[peerOnion]?.isConnected == true) return;

    final nudge = nudgePeerForInbound;
    if (nudge != null) {
      try {
        await nudge(peerOnion);
      } catch (_) {}
    }
    warmPeer(peerOnion);
  }

  @visibleForTesting
  void registerLinkForTest(
    String peerOnion,
    WsPeerLink link, {
    bool outbound = false,
  }) {
    _registerLink(peerOnion, link, outbound: outbound);
  }

  @visibleForTesting
  void recordConnectFailureForTest(String peerOnion, Object error) {
    _recordConnectFailure(peerOnion, error);
  }

  @visibleForTesting
  Duration? retryDelayForTest(String peerOnion) {
    final retryAfter = _nextRetryAfter[peerOnion];
    if (retryAfter == null) return null;
    final remaining = retryAfter.difference(DateTime.now());
    return remaining.isNegative ? Duration.zero : remaining;
  }

  void dispose() {
    _disposed = true;
    stop();
  }
}
