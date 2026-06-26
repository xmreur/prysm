import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:prysm/client/TorHttpClient.dart';
import 'package:prysm/transport/outbound_transport.dart';
import 'package:prysm/util/tor_delivery.dart';
import 'package:prysm/util/tor_runtime_gate.dart';
import 'package:prysm/util/tor_service.dart';

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

  TorHttpClient _client() {
    return TorHttpClient(
      proxyHost: '127.0.0.1',
      proxyPort: _torManager.socksPort,
    );
  }

  @override
  Future<T> runForPeer<T>(String peerOnion, Future<T> Function() operation) {
    if (TorRuntimeGate.blocked) {
      return Future.error(StateError('Tor is stopped'));
    }

    return _runWithRetry(peerOnion, operation);
  }

  Future<T> _runWithRetry<T>(
    String peerOnion,
    Future<T> Function() operation,
  ) async {
    outboundQueueDepth++;
    try {
      if (TorRuntimeGate.blocked) {
        throw StateError('Tor is stopped');
      }
      final result = await TorDelivery.withTorRetry(attempt: operation);
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
  }) {
    return runForPeer(peerOnion, () async {
      final client = _client();
      try {
        final response = await client
            .get(Uri.parse('http://$peerOnion:80/profile'), {})
            .timeout(timeout);
        return client.readUtf8Body(response);
      } finally {
        client.close();
      }
    });
  }

  @override
  Future<String> getPublic(
    String peerOnion, {
    Duration timeout = const Duration(seconds: 20),
  }) {
    return runForPeer(peerOnion, () async {
      final client = _client();
      try {
        final response = await client
            .get(Uri.parse('http://$peerOnion:80/public'), {})
            .timeout(timeout);
        return client.readUtf8Body(response);
      } finally {
        client.close();
      }
    });
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
        await client.readUtf8Body(response);
      } finally {
        client.close();
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
