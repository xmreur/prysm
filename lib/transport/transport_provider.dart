import 'dart:async';
import 'dart:convert';

import 'package:prysm/client/TorHttpClient.dart';
import 'package:prysm/services/ws_connection_manager.dart';
import 'package:prysm/transport/outbound_transport.dart';
import 'package:prysm/transport/peer_transport_registry.dart';
import 'package:prysm/transport/tor_http_transport.dart';
import 'package:prysm/transport/tor_websocket_transport.dart';
import 'package:prysm/transport/transport_preference.dart';
import 'package:prysm/util/file_transfer_policy.dart';
import 'package:prysm/util/local_onion_address.dart';
import 'package:prysm/util/logging.dart';
import 'package:prysm/util/profile_http_uri.dart';
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

  /// Tries to restore a WebSocket after HTTP fallback or disconnect.
  Future<void> recoverWebSocket(String peerOnion) async {
    if (isRealtimeConnected(peerOnion)) return;

    _wsManager.warmPeer(peerOnion);
    if (isRealtimeConnected(peerOnion)) return;

    try {
      await _wsManager.ensureConnected(
        peerOnion,
        connectBudget: WsConnectionManager.interactiveConnectBudget,
      );
    } catch (_) {}

    if (isRealtimeConnected(peerOnion)) return;

    try {
      await postSyncHint(peerOnion: peerOnion);
    } catch (_) {}
  }

  void _scheduleWebSocketRecovery(String peerOnion) {
    unawaited(recoverWebSocket(peerOnion));
  }

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
      final result = await operation(_httpTransport);
      _scheduleWebSocketRecovery(peerOnion);
      return result;
    }

    if (_wsManager.isConnected(peerOnion)) {
      try {
        final result = await operation(_wsTransport);
        PeerTransportRegistry.instance.markWebSocket(peerOnion);
        Logging.debug('TransportProvider: WS $peerOnion (${preference.name})', 'TransportProvider');
        
        return result;
      } catch (e) {
        Logging.error('WS failed for $peerOnion (${preference.name}): $e', 'TransportProvider');
        if (_shouldDisconnectWsAfterFailure(e)) {
          await _wsManager.disconnectPeer(peerOnion);
        }
        if (preference != TransportPreference.httpOnly) {
          _scheduleWebSocketRecovery(peerOnion);
        }
      }
    }

    Logging.debug('HTTP $peerOnion (${preference.name})', 'TransportProvider');
    final result = await operation(_httpTransport);
    if (preference != TransportPreference.httpOnly) {
      _scheduleWebSocketRecovery(peerOnion);
    }
    return result;
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
  Future<T> runForPeer<T>(
    String peerOnion,
    Future<T> Function() operation, {
    int maxAttempts = TorDelivery.defaultMaxAttempts,
  }) =>
      withPeer(
        peerOnion,
        (transport) => transport.runForPeer(
          peerOnion,
          operation,
          maxAttempts: maxAttempts,
        ),
      );

  @override
  Future<String> getProfile(
    String peerOnion, {
    Duration timeout = const Duration(seconds: 20),
    int maxAttempts = TorDelivery.defaultMaxAttempts,
  }) => getProfileWithPreference(
    peerOnion,
    timeout: timeout,
    maxAttempts: maxAttempts,
  );

  Future<String> getProfileWithPreference(
    String peerOnion, {
    Duration timeout = const Duration(seconds: 20),
    TransportPreference preference = TransportPreference.wsPreferred,
    int maxAttempts = TorDelivery.defaultMaxAttempts,
  }) => withPeer(
    peerOnion,
    (transport) => transport.getProfile(
      peerOnion,
      timeout: timeout,
      maxAttempts: maxAttempts,
    ),
    preference: preference,
  );

  @override
  Future<String> getPublic(
    String peerOnion, {
    Duration timeout = const Duration(seconds: 20),
    int maxAttempts = TorDelivery.defaultMaxAttempts,
  }) => getPublicWithPreference(
    peerOnion,
    timeout: timeout,
    maxAttempts: maxAttempts,
  );

  Future<String> getPublicWithPreference(
    String peerOnion, {
    Duration timeout = const Duration(seconds: 20),
    TransportPreference preference = TransportPreference.wsPreferred,
    int maxAttempts = TorDelivery.defaultMaxAttempts,
  }) => withPeer(
    peerOnion,
    (transport) => transport.getPublic(
      peerOnion,
      timeout: timeout,
      maxAttempts: maxAttempts,
    ),
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
    int maxAttempts = TorDelivery.defaultMaxAttempts,
  }) async {
    if (isConfigured) {
      return instance.getProfileWithPreference(
        peerOnion,
        timeout: timeout,
        preference: preference,
        maxAttempts: maxAttempts,
      );
    }
    return TorDelivery.withTorRetry<String>(
      maxAttempts: maxAttempts,
      attempt: () async {
        final torClient = TorHttpClient(
          proxyHost: '127.0.0.1',
          proxyPort: socksPort,
        );
        try {
          final requester = LocalOnionAddress.value;
          final uri = ProfileHttpUri.build(
            peerOnion,
            requesterOnion: requester,
          );
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
    int maxAttempts = TorDelivery.defaultMaxAttempts,
  }) async {
    if (isConfigured) {
      return instance.getPublicWithPreference(
        peerOnion,
        timeout: timeout,
        preference: preference,
        maxAttempts: maxAttempts,
      );
    }
    return TorDelivery.withTorRetry<String>(
      maxAttempts: maxAttempts,
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
      final skipWsForLargePayload =
          FileTransferPolicy.shouldAvoidWsMonolithicSend(payload);
      if (skipWsForLargePayload) {
        Logging.debug(
          'Skipping WS for large payload to $peerOnion → HTTP',
          'TransportProvider',
        );
      }
      if (inst.isRealtimeConnected(peerOnion) && !skipWsForLargePayload) {
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
            Logging.debug('WS send ok $peerOnion', 'TransportProvider');
            return;
          } catch (e) {
            lastWsError = e;
            final retryTimeout = e is TimeoutException && attempt == 0;
            if (!retryTimeout) break;
            Logging.error('WS send timeout ($peerOnion), retrying once', 'TransportProvider');
          }
        }
        Logging.error('WS send failed ($peerOnion): $lastWsError → HTTP', 'TransportProvider');
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
      Logging.debug('HTTP send ok $peerOnion', 'TransportProvider');
      inst._scheduleWebSocketRecovery(peerOnion);
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
    try {
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
    } catch (e) {
      Logging.error('sync-hint to $peerOnion failed: $e', 'TransportProvider');
      
    }
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
