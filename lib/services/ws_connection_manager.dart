import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:prysm/client/tor_websocket_client.dart';
import 'package:prysm/database/messages.dart';
import 'package:prysm/services/ws_inbound_dispatcher.dart';
import 'package:prysm/transport/inbound_ws_peer_link.dart';
import 'package:prysm/transport/outbound_ws_peer_link.dart';
import 'package:prysm/transport/peer_transport_registry.dart';
import 'package:prysm/transport/ws_dial_policy.dart';
import 'package:prysm/transport/ws_peer_link.dart';
import 'package:prysm/util/battery_saver_policy.dart';
import 'package:prysm/util/tor_delivery.dart';
import 'package:prysm/util/tor_runtime_gate.dart';
import 'package:prysm/util/tor_service.dart';

/// Maintains one full-duplex WebSocket link per peer (dialer or acceptor).
class WsConnectionManager {
  WsConnectionManager(this._torManager);

  static const Duration interactiveConnectBudget = Duration(seconds: 25);

  static const Duration backgroundConnectTimeout = Duration(seconds: 30);
  static const Duration _maxReconnectBackoff = Duration(minutes: 2);
  static const int _maxPingFailures = 3;

  final TorManager _torManager;
  final Map<String, WsPeerLink> _links = {};
  final Map<String, Future<void>> _connectChains = {};
  final Map<String, Future<void>> _requestChains = {};
  final Map<String, int> _requestQueueDepthByPeer = {};
  final Map<String, int> _connectFailures = {};
  final Map<String, int> _pingFailures = {};
  final Map<String, DateTime> _lastSuccessByPeer = {};
  final Map<String, DateTime> _nextRetryAfter = {};
  final Map<String, List<Completer<void>>> _inboundWaiters = {};
  final Set<String> _connectingPeers = {};
  final Set<String> _pinnedPeers = {};
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

  void pinPeer(String peerOnion) => _pinnedPeers.add(peerOnion);

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
      } catch (_) {
        _recordConnectFailure(peer);
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

  void _recordConnectFailure(String peerOnion) {
    final failures = (_connectFailures[peerOnion] ?? 0) + 1;
    _connectFailures[peerOnion] = failures;

    final backoffSeconds = failures <= 6 ? (1 << (failures - 1)) : 120;
    final backoff = Duration(
      seconds: backoffSeconds.clamp(1, _maxReconnectBackoff.inSeconds),
    );
    _nextRetryAfter[peerOnion] = DateTime.now().add(backoff);
  }

  void prepareForTorReconnect() {
    _connectFailures.clear();
    _nextRetryAfter.clear();
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
      if (kDebugMode) {
        debugPrint('WsConnectionManager: DB not ready for peer targets: $e');
      }
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
    if (connectBudget == null && _isInBackoff(peerOnion)) {
      return Future.error(StateError('Peer reconnect backoff active'));
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
        );
        await client.connect(timeout: connectTimeout);
        final link = OutboundWsPeerLink(client);
        _registerLink(peerOnion, link, outbound: true);
        if (kDebugMode) {
          debugPrint('WsConnectionManager: connected to $peerOnion');
        }
      }

      if (useTorRetry) {
        await TorDelivery.withTorRetry<void>(attempt: connectOnce);
      } else {
        await connectOnce();
      }
    } catch (e, stack) {
      if (kDebugMode) {
        debugPrint('WsConnectionManager: connect to $peerOnion failed: $e');
        if (!useTorRetry) {
          debugPrint('$stack');
        }
      }
      rethrow;
    } finally {
      _connectingPeers.remove(peerOnion);
    }
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
      debugPrint('WsConnectionManager: accepted from $peerOnion');
    }
  }

  void _registerLink(
    String peerOnion,
    WsPeerLink link, {
    required bool outbound,
  }) {
    _links[peerOnion] = link;
    WsInboundDispatcher.instance.attach(peerOnion, link.onPushFrames);
    PeerTransportRegistry.instance.markWebSocket(peerOnion);
    _connectFailures.remove(peerOnion);
    _nextRetryAfter.remove(peerOnion);
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
  }) {
    return _enqueueRequest(peerOnion, () async {
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
    });
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

  Future<void> disconnectPeer(String peerOnion) => _removeLink(peerOnion);

  Future<void> _removeLink(String peerOnion) async {
    final link = _links.remove(peerOnion);
    if (link == null) return;

    WsInboundDispatcher.instance.detach(peerOnion);
    await link.close();
    onPeerDisconnected?.call(peerOnion);
  }

  @visibleForTesting
  void registerLinkForTest(
    String peerOnion,
    WsPeerLink link, {
    bool outbound = false,
  }) {
    _registerLink(peerOnion, link, outbound: outbound);
  }

  void dispose() {
    _disposed = true;
    stop();
  }
}
