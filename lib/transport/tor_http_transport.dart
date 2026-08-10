import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:prysm/client/TorHttpClient.dart';
import 'package:prysm/transport/outbound_transport.dart';
import 'package:prysm/util/local_onion_address.dart';
import 'package:prysm/util/profile_http_uri.dart';
import 'package:prysm/util/tor_delivery.dart';
import 'package:prysm/util/tor_runtime_gate.dart';
import 'package:prysm/util/tor_service.dart';

/// A peer answered a request with a non-2xx status.
///
/// The response body is deliberately *not* carried here. [TorDelivery]
/// classifies retries and circuit resets by substring on the error text
/// (`isRetryableError` / `isCircuitError`), so a peer-controlled body would
/// let the peer pick its own classification: answering `4xx` with
/// `hostUnreachable` in the body would buy it three retries and a global
/// NEWNYM per delivery. The status code is ours, and it is all the callers
/// and logs need.
class PeerHttpStatusException implements Exception {
  const PeerHttpStatusException(this.statusCode);

  final int statusCode;

  @override
  String toString() => 'Peer answered HTTP $statusCode';
}

/// HTTP request/response transport over Tor SOCKS.
class TorHttpTransport implements OutboundTransport {
  TorHttpTransport(this._torManager);

  final TorManager _torManager;
  final Map<String, DateTime> _lastSuccessByPeer = {};

  @override
  int outboundQueueDepth = 0;

  @override
  DateTime? lastSuccessForPeer(String peerOnion) =>
      _lastSuccessByPeer[peerOnion];

  /// Test seam: replaces the per-request [TorHttpClient] so transport-level
  /// status handling can be exercised without a live Tor circuit. The
  /// production [postJson] body (retry, body read, status check) still runs.
  @visibleForTesting
  static TorHttpClient Function()? clientFactory;

  TorHttpClient _client() {
    final factory = clientFactory;
    if (factory != null) return factory();
    return TorHttpClient(
      proxyHost: '127.0.0.1',
      proxyPort: _torManager.socksPort,
    );
  }

  @override
  Future<T> runForPeer<T>(
    String peerOnion,
    Future<T> Function() operation, {
    int maxAttempts = TorDelivery.defaultMaxAttempts,
  }) {
    if (TorRuntimeGate.blocked) {
      return Future.error(StateError('Tor is stopped'));
    }

    return _runWithRetry(
      peerOnion,
      operation,
      maxAttempts: maxAttempts,
    );
  }

  Future<T> _runWithRetry<T>(
    String peerOnion,
    Future<T> Function() operation, {
    int maxAttempts = TorDelivery.defaultMaxAttempts,
  }) async {
    outboundQueueDepth++;
    try {
      if (TorRuntimeGate.blocked) {
        throw StateError('Tor is stopped');
      }
      final result = await TorDelivery.withTorRetry(
        maxAttempts: maxAttempts,
        attempt: operation,
      );
      _lastSuccessByPeer[peerOnion] = DateTime.now();
      return result;
    } finally {
      outboundQueueDepth--;
    }
  }

  @override
  Future<String> getProfile(
    String peerOnion, {
    Duration timeout = const Duration(seconds: 20),
    int maxAttempts = TorDelivery.defaultMaxAttempts,
  }) {
    return runForPeer(
      peerOnion,
      () async {
      final client = _client();
      try {
        final requester = LocalOnionAddress.value;
        final uri = ProfileHttpUri.build(
          peerOnion,
          requesterOnion: requester,
        );
        final response = await client.get(uri, {}).timeout(timeout);
        return client.readUtf8Body(response);
      } finally {
        await client.close();
      }
    },
      maxAttempts: maxAttempts,
    );
  }

  @override
  Future<String> getPublic(
    String peerOnion, {
    Duration timeout = const Duration(seconds: 20),
    int maxAttempts = TorDelivery.defaultMaxAttempts,
  }) {
    return runForPeer(
      peerOnion,
      () async {
      final client = _client();
      try {
        final response = await client
            .get(Uri.parse('http://$peerOnion:80/public'), {})
            .timeout(timeout);
        return client.readUtf8Body(response);
      } finally {
        await client.close();
      }
    },
      maxAttempts: maxAttempts,
    );
  }

  @override
  Future<void> postMessage({
    required String peerOnion,
    required Map<String, dynamic> payload,
    Duration timeout = const Duration(seconds: 30),
  }) {
    return postJson(
      peerOnion: peerOnion,
      path: 'message',
      payload: payload,
      timeout: timeout,
    );
  }

  @override
  Future<void> postJson({
    required String peerOnion,
    required String path,
    required Map<String, dynamic> payload,
    Duration timeout = const Duration(seconds: 30),
  }) {
    return runForPeer(peerOnion, () async {
      final client = _client();
      try {
        final response = await client
            .post(
              Uri.parse('http://$peerOnion:80/$path'),
              {'Content-Type': 'application/json'},
              jsonEncode(payload),
            )
            .timeout(timeout);
        // Drain the body so the SOCKS socket is released, then discard it:
        // it is peer-controlled and nothing here consumes it.
        await client.readUtf8Body(response);
        if (response.statusCode < 200 || response.statusCode >= 300) {
          // The peer is reachable and answered, but rejected the payload
          // (4xx) or failed to process it (5xx). Surface it as a failure so
          // callers queue a retry instead of reporting a phantom success —
          // the same signal the WebSocket path produces via ack errors.
          throw PeerHttpStatusException(response.statusCode);
        }
      } finally {
        await client.close();
      }
    });
  }

  @override
  void dispose() {
    // Each request uses its own client; nothing to close globally.
  }

  @visibleForTesting
  static TorHttpTransport createForTest(TorManager torManager) {
    return TorHttpTransport(torManager);
  }
}
