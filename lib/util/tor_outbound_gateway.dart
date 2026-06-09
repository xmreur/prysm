import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:prysm/client/TorHttpClient.dart';
import 'package:prysm/util/tor_delivery.dart';
import 'package:prysm/util/tor_runtime_gate.dart';
import 'package:prysm/util/tor_service.dart';

/// Shared SOCKS client, per-peer send serialization, and unified Tor HTTP helpers.
class TorOutboundGateway {
  TorOutboundGateway._(this._torManager);

  static TorOutboundGateway? _instance;

  static TorOutboundGateway get instance {
    final i = _instance;
    if (i == null) {
      throw StateError('TorOutboundGateway.configure() must be called first');
    }
    return i;
  }

  static bool get isConfigured => _instance != null;

  static void configure(TorManager torManager) {
    _instance?.dispose();
    _instance = TorOutboundGateway._(torManager);
    TorDelivery.configure(torManager);
  }

  @visibleForTesting
  static void resetForTest() {
    _instance?.dispose();
    _instance = null;
  }

  final TorManager _torManager;
  TorHttpClient? _sharedClient;
  final Map<String, Future<void>> _peerChains = {};
  final Map<String, DateTime> _lastSuccessByPeer = {};

  int outboundQueueDepth = 0;

  DateTime? lastSuccessForPeer(String peerOnion) => _lastSuccessByPeer[peerOnion];

  TorHttpClient _client() {
    _sharedClient ??= TorHttpClient(
      proxyHost: '127.0.0.1',
      proxyPort: _torManager.socksPort,
    );
    return _sharedClient!;
  }

  Future<T> runForPeer<T>(String peerOnion, Future<T> Function() operation) {
    if (TorRuntimeGate.blocked) {
      return Future.error(StateError('Tor is stopped'));
    }

    final prev = _peerChains[peerOnion] ?? Future<void>.value();
    late final Future<T> chained;
    chained = prev.then((_) async {
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
    });
    _peerChains[peerOnion] =
        chained.then((_) {}, onError: (_) {});
    return chained;
  }

  Future<String> getProfile(
    String peerOnion, {
    Duration timeout = const Duration(seconds: 20),
  }) {
    return runForPeer(peerOnion, () async {
      final client = _client();
      final response = await client
          .get(Uri.parse('http://$peerOnion:80/profile'), {})
          .timeout(timeout);
      return client.readUtf8Body(response);
    });
  }

  Future<String> getPublic(
    String peerOnion, {
    Duration timeout = const Duration(seconds: 20),
  }) {
    return runForPeer(peerOnion, () async {
      final client = _client();
      final response = await client
          .get(Uri.parse('http://$peerOnion:80/public'), {})
          .timeout(timeout);
      return client.readUtf8Body(response);
    });
  }

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

  Future<void> postJson({
    required String peerOnion,
    required String path,
    required Map<String, dynamic> payload,
    Duration timeout = const Duration(seconds: 30),
  }) {
    return runForPeer(peerOnion, () async {
      final client = _client();
      final response = await client
          .post(
            Uri.parse('http://$peerOnion:80/$path'),
            {'Content-Type': 'application/json'},
            jsonEncode(payload),
          )
          .timeout(timeout);
      await client.readUtf8Body(response);
    });
  }

  void dispose() {
    _sharedClient?.close();
    _sharedClient = null;
    _peerChains.clear();
  }
}
