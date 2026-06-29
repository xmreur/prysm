import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:prysm/client/TorHttpClient.dart';
import 'package:prysm/services/ws_connection_manager.dart';
import 'package:prysm/transport/outbound_transport.dart';
import 'package:prysm/transport/peer_transport_registry.dart';
import 'package:prysm/transport/tor_http_transport.dart';
import 'package:prysm/transport/tor_websocket_transport.dart';
import 'package:prysm/transport/transport_preference.dart';
import 'package:prysm/util/tor_delivery.dart';
import 'package:prysm/util/tor_service.dart';

/// Selects HTTP or WebSocket transport per peer with automatic fallback.
class TransportProvider implements OutboundTransport {
  TransportProvider._(TorManager torManager)
    : _torManager = torManager,
      _httpTransport = TorHttpTransport(torManager),
      _wsManager = WsConnectionManager(torManager) {
    _wsTransport = TorWebSocketTransport(_wsManager);
  }

  static TransportProvider? _instance;

  final TorManager _torManager;

  static TransportProvider get instance {
    final i = _instance;
    if (i == null) {
      throw StateError('TransportProvider.configure() must be called first');
    }
    return i;
  }

  static bool get isConfigured => _instance != null;

  static void configure(
    TorManager torManager, {
    Future<bool> Function(String peerId)? onPeerConnected,
  }) {
    final existing = _instance;
    if (existing != null && identical(existing._torManager, torManager)) {
      existing._wsManager.onPeerConnected = onPeerConnected;
      existing._wsManager.nudgePeerForInbound = existing._nudgePeerForInbound;
      TorDelivery.configure(torManager);
      return;
    }
    _instance?.dispose();
    final provider = TransportProvider._(torManager);
    provider._wsManager.onPeerConnected = onPeerConnected;
    provider._wsManager.nudgePeerForInbound = provider._nudgePeerForInbound;
    _instance = provider;
    TorDelivery.configure(torManager);
  }

  static void resetForTest() {
    _instance?.dispose();
    _instance = null;
    PeerTransportRegistry.instance.resetForTest();
  }

  final TorHttpTransport _httpTransport;
  final WsConnectionManager _wsManager;
  late final TorWebSocketTransport _wsTransport;

  WsConnectionManager get wsManager => _wsManager;

  Future<void> _nudgePeerForInbound(String peerOnion) =>
      postSyncHint(peerOnion: peerOnion);

  TorHttpTransport get httpTransport => _httpTransport;

  bool isRealtimeConnected(String peerOnion) =>
      _wsManager.isConnected(peerOnion);

  void startWebSocketConnections() {
    _wsManager.start();
  }

  void stopWebSocketConnections() {
    _wsManager.stop();
  }

  void pinPeer(String peerOnion) {
    _wsManager.pinPeer(peerOnion);
    _wsManager.warmPeer(peerOnion);
  }

  void unpinPeer(String peerOnion) => _wsManager.unpinPeer(peerOnion);

  Future<T> withPeer<T>(
    String peerOnion,
    Future<T> Function(OutboundTransport transport) operation, {
    TransportPreference preference = TransportPreference.wsPreferred,
  }) async {
    if (preference == TransportPreference.httpOnly) {
      return operation(_httpTransport);
    }

    if (preference == TransportPreference.wsPreferred &&
        !_wsManager.isConnected(peerOnion)) {
      try {
        await _wsManager.ensureConnected(
          peerOnion,
          connectBudget: WsConnectionManager.interactiveConnectBudget,
        );
      } catch (_) {
        // Fall through to HTTP below.
      }
    }

    if (preference == TransportPreference.wsIfConnected &&
        !_wsManager.isConnected(peerOnion)) {
      return operation(_httpTransport);
    }

    if (_wsManager.isConnected(peerOnion)) {
      try {
        final result = await operation(_wsTransport);
        PeerTransportRegistry.instance.markWebSocket(peerOnion);
        if (kDebugMode) {
          debugPrint('TransportProvider: WS $peerOnion (${preference.name})');
        }
        return result;
      } catch (e) {
        if (kDebugMode) {
          debugPrint(
            'TransportProvider: WS failed for $peerOnion (${preference.name}): $e',
          );
        }
        if (_shouldDisconnectWsAfterFailure(e)) {
          await _wsManager.disconnectPeer(peerOnion);
        }
      }
    }

    if (kDebugMode) {
      debugPrint('TransportProvider: HTTP $peerOnion (${preference.name})');
    }
    return operation(_httpTransport);
  }

  @override
  int get outboundQueueDepth =>
      _httpTransport.outboundQueueDepth + _wsManager.outboundQueueDepth;

  @override
  DateTime? lastSuccessForPeer(String peerOnion) {
    return _wsManager.lastSuccessForPeer(peerOnion) ??
        _httpTransport.lastSuccessForPeer(peerOnion);
  }

  @override
  Future<T> runForPeer<T>(String peerOnion, Future<T> Function() operation) =>
      withPeer(
        peerOnion,
        (transport) => transport.runForPeer(peerOnion, operation),
      );

  @override
  Future<String> getProfile(
    String peerOnion, {
    Duration timeout = const Duration(seconds: 20),
  }) => getProfileWithPreference(peerOnion, timeout: timeout);

  Future<String> getProfileWithPreference(
    String peerOnion, {
    Duration timeout = const Duration(seconds: 20),
    TransportPreference preference = TransportPreference.wsPreferred,
  }) => withPeer(
    peerOnion,
    (transport) => transport.getProfile(peerOnion, timeout: timeout),
    preference: preference,
  );

  @override
  Future<String> getPublic(
    String peerOnion, {
    Duration timeout = const Duration(seconds: 20),
  }) => getPublicWithPreference(peerOnion, timeout: timeout);

  Future<String> getPublicWithPreference(
    String peerOnion, {
    Duration timeout = const Duration(seconds: 20),
    TransportPreference preference = TransportPreference.wsPreferred,
  }) => withPeer(
    peerOnion,
    (transport) => transport.getPublic(peerOnion, timeout: timeout),
    preference: preference,
  );

  @override
  Future<void> postMessage({
    required String peerOnion,
    required Map<String, dynamic> payload,
    Duration timeout = const Duration(seconds: 30),
  }) => postMessageWithPreference(
    peerOnion: peerOnion,
    payload: payload,
    timeout: timeout,
  );

  Future<void> postMessageWithPreference({
    required String peerOnion,
    required Map<String, dynamic> payload,
    Duration timeout = const Duration(seconds: 30),
    TransportPreference preference = TransportPreference.wsPreferred,
  }) => withPeer(
    peerOnion,
    (transport) => transport.postMessage(
      peerOnion: peerOnion,
      payload: payload,
      timeout: timeout,
    ),
    preference: preference,
  );

  @override
  Future<void> postJson({
    required String peerOnion,
    required String path,
    required Map<String, dynamic> payload,
    Duration timeout = const Duration(seconds: 30),
  }) => postJsonWithPreference(
    peerOnion: peerOnion,
    path: path,
    payload: payload,
    timeout: timeout,
  );

  Future<void> postJsonWithPreference({
    required String peerOnion,
    required String path,
    required Map<String, dynamic> payload,
    Duration timeout = const Duration(seconds: 30),
    TransportPreference preference = TransportPreference.wsPreferred,
  }) => withPeer(
    peerOnion,
    (transport) => transport.postJson(
      peerOnion: peerOnion,
      path: path,
      payload: payload,
      timeout: timeout,
    ),
    preference: preference,
  );

  /// Unified outbound helper used when Tor may not yet be configured.
  static Future<String> getProfileOrFallback(
    String peerOnion, {
    Duration timeout = const Duration(seconds: 20),
    int socksPort = 9050,
    TransportPreference preference = TransportPreference.wsPreferred,
  }) async {
    if (isConfigured) {
      return instance.getProfileWithPreference(
        peerOnion,
        timeout: timeout,
        preference: preference,
      );
    }
    return TorDelivery.withTorRetry<String>(
      attempt: () async {
        final torClient = TorHttpClient(
          proxyHost: '127.0.0.1',
          proxyPort: socksPort,
        );
        try {
          final uri = Uri.parse('http://$peerOnion:80/profile');
          final response = await torClient.get(uri, {}).timeout(timeout);
          return torClient.readUtf8Body(response);
        } finally {
          await torClient.close();
        }
      },
    );
  }

  static Future<String> getPublicOrFallback(
    String peerOnion, {
    Duration timeout = const Duration(seconds: 20),
    int socksPort = 9050,
    TransportPreference preference = TransportPreference.wsPreferred,
  }) async {
    if (isConfigured) {
      return instance.getPublicWithPreference(
        peerOnion,
        timeout: timeout,
        preference: preference,
      );
    }
    return TorDelivery.withTorRetry<String>(
      attempt: () async {
        final torClient = TorHttpClient(
          proxyHost: '127.0.0.1',
          proxyPort: socksPort,
        );
        try {
          final uri = Uri.parse('http://$peerOnion:80/public');
          final response = await torClient.get(uri, {}).timeout(timeout);
          return torClient.readUtf8Body(response);
        } finally {
          await torClient.close();
        }
      },
    );
  }

  static const Duration _wsSendBudget = Duration(seconds: 30);

  static bool _shouldDisconnectWsAfterFailure(Object error) {
    if (error is TimeoutException) return false;
    if (error is StateError) {
      final message = error.message.toLowerCase();
      return message.contains('not connected') ||
          message.contains('disconnected');
    }
    return true;
  }

  static Duration _wsSendTimeoutFor(Duration requested) {
    if (requested > _wsSendBudget) return requested;
    return requested < _wsSendBudget ? requested : _wsSendBudget;
  }

  static Future<void> postMessageOrFallback({
    required String peerOnion,
    required Map<String, dynamic> payload,
    Duration timeout = const Duration(seconds: 30),
    int socksPort = 9050,
  }) async {
    if (isConfigured) {
      final inst = instance;
      if (!inst.isRealtimeConnected(peerOnion)) {
        try {
          await inst.wsManager.ensureConnected(
            peerOnion,
            connectBudget: WsConnectionManager.interactiveConnectBudget,
          );
        } catch (_) {
          // Fall through to HTTP below.
        }
      }
      if (inst.isRealtimeConnected(peerOnion)) {
        final wsTimeout = _wsSendTimeoutFor(timeout);
        Object? lastWsError;
        for (var attempt = 0; attempt < 2; attempt++) {
          try {
            await inst.postMessageWithPreference(
              peerOnion: peerOnion,
              payload: payload,
              timeout: wsTimeout,
              preference: TransportPreference.wsIfConnected,
            );
            if (kDebugMode) {
              debugPrint('TransportProvider: WS send ok $peerOnion');
            }
            return;
          } catch (e) {
            lastWsError = e;
            final retryTimeout = e is TimeoutException && attempt == 0;
            if (!retryTimeout) break;
            if (kDebugMode) {
              debugPrint(
                'TransportProvider: WS send timeout ($peerOnion), retrying once',
              );
            }
          }
        }
        if (kDebugMode) {
          debugPrint(
            'TransportProvider: WS send failed ($peerOnion): $lastWsError → HTTP',
          );
        }
        if (lastWsError != null &&
            _shouldDisconnectWsAfterFailure(lastWsError)) {
          await inst.wsManager.disconnectPeer(peerOnion);
        }
      }
      await inst.postMessageWithPreference(
        peerOnion: peerOnion,
        payload: payload,
        timeout: timeout,
        preference: TransportPreference.httpOnly,
      );
      if (kDebugMode) {
        debugPrint('TransportProvider: HTTP send ok $peerOnion');
      }
      return;
    }
    await TorDelivery.withTorRetry<void>(
      attempt: () async {
        final torClient = TorHttpClient(
          proxyHost: '127.0.0.1',
          proxyPort: socksPort,
        );
        try {
          final uri = Uri.parse('http://$peerOnion:80/message');
          final response = await torClient
              .post(uri, {
                'Content-Type': 'application/json',
              }, jsonEncode(payload))
              .timeout(timeout);
          await torClient.readUtf8Body(response);
        } finally {
          await torClient.close();
        }
      },
    );
  }

  static Future<void> postSyncHint({
    required String peerOnion,
    String? senderId,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final localSender = senderId;
    if (localSender == null || localSender.isEmpty) {
      if (!isConfigured) return;
      final onion = await instance._torManager.getOnionAddress();
      if (onion == null || onion.isEmpty) return;
      return postSyncHint(
        peerOnion: peerOnion,
        senderId: onion,
        timeout: timeout,
      );
    }

    await postJsonOrFallback(
      peerOnion: peerOnion,
      path: 'sync-hint',
      payload: {
        'senderId': localSender,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      },
      timeout: timeout,
    );
  }

  static Future<void> postJsonOrFallback({
    required String peerOnion,
    required String path,
    required Map<String, dynamic> payload,
    Duration timeout = const Duration(seconds: 30),
    int socksPort = 9050,
  }) async {
    if (isConfigured) {
      await instance.postJsonWithPreference(
        peerOnion: peerOnion,
        path: path,
        payload: payload,
        timeout: timeout,
        preference: TransportPreference.httpOnly,
      );
      return;
    }
    await TorDelivery.withTorRetry<void>(
      attempt: () async {
        final torClient = TorHttpClient(
          proxyHost: '127.0.0.1',
          proxyPort: socksPort,
        );
        try {
          final uri = Uri.parse('http://$peerOnion:80/$path');
          final response = await torClient
              .post(uri, {
                'Content-Type': 'application/json',
              }, jsonEncode(payload))
              .timeout(timeout);
          await torClient.readUtf8Body(response);
        } finally {
          await torClient.close();
        }
      },
    );
  }

  @override
  void dispose() {
    _wsManager.dispose();
    _httpTransport.dispose();
  }
}
