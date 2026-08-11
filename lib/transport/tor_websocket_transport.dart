import 'dart:convert';

import 'package:prysm/services/ws_connection_manager.dart';
import 'package:prysm/transport/outbound_transport.dart';
import 'package:prysm/transport/ws_protocol.dart';
import 'package:prysm/util/tor_delivery.dart';

/// WebSocket transport delegating to [WsConnectionManager].
class TorWebSocketTransport implements OutboundTransport {
  TorWebSocketTransport(this._manager);

  final WsConnectionManager _manager;

  @override
  int get outboundQueueDepth => _manager.outboundQueueDepth;

  @override
  DateTime? lastSuccessForPeer(String peerOnion) =>
      _manager.lastSuccessForPeer(peerOnion);

  @override
  Future<T> runForPeer<T>(
    String peerOnion,
    Future<T> Function() operation, {
    int maxAttempts = TorDelivery.defaultMaxAttempts,
  }) =>
      _manager.runForPeer(peerOnion, operation);

  @override
  Future<String> getProfile(
    String peerOnion, {
    Duration timeout = const Duration(seconds: 20),
    int maxAttempts = TorDelivery.defaultMaxAttempts,
  }) {
    return runForPeer(peerOnion, () async {
      final response = await _manager.request(
        peerOnion,
        'get_profile',
        timeout: timeout,
      );
      return jsonEncode(response);
    });
  }

  @override
  Future<String> getPublic(
    String peerOnion, {
    Duration timeout = const Duration(seconds: 20),
    int maxAttempts = TorDelivery.defaultMaxAttempts,
  }) {
    return runForPeer(peerOnion, () async {
      final response = await _manager.request(
        peerOnion,
        'get_public',
        timeout: timeout,
      );
      final key = response['publicKeyPem'];
      if (key is String) return key;
      throw StateError('Missing publicKeyPem in WS response');
    });
  }

  // Healthy acks take 0.22-0.47 s, worst healthy wire 6.5 s: 8 s never bites
  // a healthy link and bounds a wrong "connected" guess.
  static const Duration _wsAckCap = Duration(seconds: 8);

  @override
  Future<void> postMessage({
    required String peerOnion,
    required Map<String, dynamic> payload,
    Duration timeout = const Duration(seconds: 30),
  }) {
    final op = wsOpForPayloadType(payload['type'] as String? ?? 'text');
    return runForPeer(peerOnion, () async {
      final ack = await _manager.request(
        peerOnion,
        op,
        payload: payload,
        // WS leg only; the HTTP fallback keeps the full timeout for its own.
        timeout: timeout < _wsAckCap ? timeout : _wsAckCap,
      );
      final error = ack['error'];
      if (error != null) {
        throw StateError(error.toString());
      }
    });
  }

  @override
  Future<void> postJson({
    required String peerOnion,
    required String path,
    required Map<String, dynamic> payload,
    Duration timeout = const Duration(seconds: 30),
  }) {
    return runForPeer(peerOnion, () async {
      final op = path == 'sync-hint' ? 'sync-hint' : path;
      await _manager.send(peerOnion, op, payload: payload);
    });
  }

  @override
  void dispose() {}
}
