import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:prysm/client/tor_websocket_client.dart';
import 'package:prysm/database/messages.dart';
import 'package:prysm/services/ws_inbound_dispatcher.dart';
import 'package:prysm/transport/peer_transport_registry.dart';
import 'package:prysm/util/battery_saver_policy.dart';
import 'package:prysm/util/tor_delivery.dart';
import 'package:prysm/util/tor_runtime_gate.dart';
import 'package:prysm/util/tor_service.dart';

/// Maintains persistent WebSocket connections to recent and pinned peers.
class WsConnectionManager {
  WsConnectionManager(this._torManager);

  static Duration get interactiveConnectBudget => Platform.isAndroid
      ? const Duration(seconds: 25)
      : const Duration(seconds: 12);

  static const Duration backgroundConnectTimeout = Duration(seconds: 30);
  static const int _httpOnlyFailureThreshold = 5;
  static const Duration _maxReconnectBackoff = Duration(minutes: 2);

  final TorManager _torManager;
  final Map<String, TorWebSocketClient> _clients = {};
  final Map<String, Future<void>> _connectChains = {};
  final Map<String, int> _connectFailures = {};
  final Map<String, DateTime> _lastSuccessByPeer = {};
  final Map<String, DateTime> _nextRetryAfter = {};
  final Set<String> _connectingPeers = {};
  final Set<String> _pinnedPeers = {};
  String? _localOnion;
  Timer? _maintainTimer;
  bool _running = false;
  bool _disposed = false;

  int outboundQueueDepth = 0;

  Future<bool> Function(String peerId)? onPeerConnected;

  DateTime? lastSuccessForPeer(String peerOnion) =>
      _lastSuccessByPeer[peerOnion];

  bool isConnected(String peerOnion) =>
      _clients[peerOnion]?.isConnected ?? false;

  bool isConnectInFlight(String peerOnion) => _connectingPeers.contains(peerOnion);

  void pinPeer(String peerOnion) => _pinnedPeers.add(peerOnion);

  void unpinPeer(String peerOnion) => _pinnedPeers.remove(peerOnion);

  static const Duration _warmDebounce = Duration(seconds: 45);
  final Map<String, DateTime> _lastWarmAttempt = {};

  /// Debounced background connect when a chat is opened (via [pinPeer]).
  void warmPeer(String peerOnion) {
    if (_disposed || !_running || TorRuntimeGate.blocked) return;
    if (PeerTransportRegistry.instance.isHttpOnly(peerOnion)) return;
    if (isConnected(peerOnion) || isConnectInFlight(peerOnion)) return;

    final last = _lastWarmAttempt[peerOnion];
    if (last != null && DateTime.now().difference(last) < _warmDebounce) {
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
    _scheduleMaintain();
  }

  void stop() {
    _running = false;
    _maintainTimer?.cancel();
    _maintainTimer = null;
    for (final client in _clients.values.toList()) {
      unawaited(_detachClient(client.peerOnion, client));
    }
    _clients.clear();
    _connectChains.clear();
    _nextRetryAfter.clear();
    _connectingPeers.clear();
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
    for (final peer in targets) {
      if (PeerTransportRegistry.instance.isHttpOnly(peer)) continue;
      if (_isInBackoff(peer)) continue;

      if (_clients[peer]?.isConnected == true) {
        if (isConnectInFlight(peer)) continue;
        try {
          await _clients[peer]!.sendPing();
        } catch (_) {
          await _disconnectPeer(peer);
        }
        continue;
      }

      if (isConnectInFlight(peer)) continue;

      try {
        await ensureConnected(peer);
        _connectFailures.remove(peer);
        _nextRetryAfter.remove(peer);
      } catch (_) {
        _recordConnectFailure(peer);
      }
    }

    final stale = _clients.keys
        .where((peer) => !targets.contains(peer) && !_pinnedPeers.contains(peer))
        .toList();
    for (final peer in stale) {
      await _disconnectPeer(peer);
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

    if (failures >= _httpOnlyFailureThreshold) {
      PeerTransportRegistry.instance.markHttpOnly(peerOnion);
    }
  }

  Future<Set<String>> _connectionTargets() async {
    final timestamps = await MessagesDb.getLastMessageTimestampsForAllUsers();
    final recent = timestamps.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final targets = recent
        .take(BatterySaverPolicy.wakeHintMaxPeers)
        .map((e) => e.key)
        .toSet();
    targets.addAll(_pinnedPeers);
    return targets;
  }

  /// Connects to [peerOnion]. When [connectBudget] is set, uses a single fast
  /// attempt (no Tor retry loop) suitable for interactive outbound ops.
  Future<void> ensureConnected(
    String peerOnion, {
    Duration? connectBudget,
  }) {
    if (_disposed || TorRuntimeGate.blocked) {
      return Future.error(StateError('Cannot connect while Tor is stopped'));
    }
    if (PeerTransportRegistry.instance.isHttpOnly(peerOnion)) {
      return Future.error(StateError('Peer marked HTTP-only'));
    }
    if (_clients[peerOnion]?.isConnected == true) {
      return Future<void>.value();
    }
    if (connectBudget == null && _isInBackoff(peerOnion)) {
      return Future.error(StateError('Peer reconnect backoff active'));
    }

    final prev = _connectChains[peerOnion] ?? Future<void>.value();
    late final Future<void> chained;
    chained = prev.then(
      (_) => _ensureConnectedOnce(
        peerOnion,
        connectTimeout: connectBudget ?? backgroundConnectTimeout,
        useTorRetry: connectBudget == null,
      ),
    );
    _connectChains[peerOnion] =
        chained.then((_) {}, onError: (_) {});
    return chained;
  }

  Future<void> _ensureConnectedOnce(
    String peerOnion, {
    required Duration connectTimeout,
    required bool useTorRetry,
  }) async {
    if (_clients[peerOnion]?.isConnected == true) return;

    final existing = _clients[peerOnion];
    if (existing != null) {
      await _disconnectPeer(peerOnion);
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
        _clients[peerOnion] = client;
        WsInboundDispatcher.instance.attach(peerOnion, client.onIncoming);
        PeerTransportRegistry.instance.markWebSocket(peerOnion);
        _connectFailures.remove(peerOnion);
        _nextRetryAfter.remove(peerOnion);
        _lastSuccessByPeer[peerOnion] = DateTime.now();
        if (kDebugMode) {
          debugPrint('WsConnectionManager: connected to $peerOnion');
        }
        final flush = onPeerConnected;
        if (flush != null) {
          unawaited(flush(peerOnion));
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
        debugPrint('$stack');
      }
      rethrow;
    } finally {
      _connectingPeers.remove(peerOnion);
    }
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
  }) async {
    if (TorRuntimeGate.blocked) {
      throw StateError('Tor is stopped');
    }
    outboundQueueDepth++;
    try {
      final client = _clients[peerOnion];
      if (client == null || !client.isConnected) {
        throw StateError('WebSocket not connected to $peerOnion');
      }
      return await client.request(op, payload: payload, timeout: timeout);
    } finally {
      outboundQueueDepth--;
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
      final client = _clients[peerOnion];
      if (client == null || !client.isConnected) {
        throw StateError('WebSocket not connected to $peerOnion');
      }
      await client.send(op, payload: payload);
      _lastSuccessByPeer[peerOnion] = DateTime.now();
    } finally {
      outboundQueueDepth--;
    }
  }

  Future<T> runForPeer<T>(String peerOnion, Future<T> Function() operation) =>
      operation();

  Future<void> disconnectPeer(String peerOnion) => _disconnectPeer(peerOnion);

  Future<void> _disconnectPeer(String peerOnion) async {
    final client = _clients.remove(peerOnion);
    if (client != null) {
      await _detachClient(peerOnion, client);
    }
  }

  Future<void> _detachClient(String peerOnion, TorWebSocketClient client) async {
    WsInboundDispatcher.instance.detach(peerOnion);
    await client.dispose();
  }

  void dispose() {
    _disposed = true;
    stop();
  }
}
