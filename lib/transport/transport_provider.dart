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
      : _httpTransport = TorHttpTransport(torManager),
        _wsManager = WsConnectionManager(torManager) {
    _wsTransport = TorWebSocketTransport(_wsManager);
  }

  static TransportProvider? _instance;

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
    _instance?.dispose();
    final provider = TransportProvider._(torManager);
    provider._wsManager.onPeerConnected = onPeerConnected;
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
    if (preference == TransportPreference.httpOnly ||
        PeerTransportRegistry.instance.isHttpOnly(peerOnion)) {
      return operation(_httpTransport);
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
        await _wsManager.disconnectPeer(peerOnion);
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
  }) =>
      getProfileWithPreference(peerOnion, timeout: timeout);

  Future<String> getProfileWithPreference(
    String peerOnion, {
    Duration timeout = const Duration(seconds: 20),
    TransportPreference preference = TransportPreference.wsPreferred,
  }) =>
      withPeer(
        peerOnion,
        (transport) => transport.getProfile(peerOnion, timeout: timeout),
        preference: preference,
      );

  @override
  Future<String> getPublic(
    String peerOnion, {
    Duration timeout = const Duration(seconds: 20),
  }) =>
      getPublicWithPreference(peerOnion, timeout: timeout);

  Future<String> getPublicWithPreference(
    String peerOnion, {
    Duration timeout = const Duration(seconds: 20),
    TransportPreference preference = TransportPreference.wsPreferred,
  }) =>
      withPeer(
        peerOnion,
        (transport) => transport.getPublic(peerOnion, timeout: timeout),
        preference: preference,
      );

  @override
  Future<void> postMessage({
    required String peerOnion,
    required Map<String, dynamic> payload,
    Duration timeout = const Duration(seconds: 30),
  }) =>
      postMessageWithPreference(
        peerOnion: peerOnion,
        payload: payload,
        timeout: timeout,
      );

  Future<void> postMessageWithPreference({
    required String peerOnion,
    required Map<String, dynamic> payload,
    Duration timeout = const Duration(seconds: 30),
    TransportPreference preference = TransportPreference.wsPreferred,
  }) =>
      withPeer(
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
  }) =>
      postJsonWithPreference(
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
  }) =>
      withPeer(
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
          torClient.close();
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
          torClient.close();
        }
      },
    );
  }

  static const Duration _wsSendBudget = Duration(seconds: 10);

  static Future<void> postMessageOrFallback({
    required String peerOnion,
    required Map<String, dynamic> payload,
    Duration timeout = const Duration(seconds: 30),
    int socksPort = 9050,
  }) async {
    if (isConfigured) {
      final inst = instance;
      if (inst.isRealtimeConnected(peerOnion)) {
        final wsTimeout =
            timeout <= _wsSendBudget ? timeout : _wsSendBudget;
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
          if (kDebugMode) {
            debugPrint(
              'TransportProvider: WS send failed ($peerOnion): $e → HTTP',
            );
          }
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
              .post(
                uri,
                {'Content-Type': 'application/json'},
                jsonEncode(payload),
              )
              .timeout(timeout);
          await torClient.readUtf8Body(response);
        } finally {
          torClient.close();
        }
      },
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
              .post(
                uri,
                {'Content-Type': 'application/json'},
                jsonEncode(payload),
              )
              .timeout(timeout);
          await torClient.readUtf8Body(response);
        } finally {
          torClient.close();
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
