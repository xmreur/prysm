import 'dart:async';

import 'package:prysm/util/tor_delivery.dart';

/// Outbound peer transport (HTTP or WebSocket over Tor).
abstract class OutboundTransport {
  int get outboundQueueDepth;

  DateTime? lastSuccessForPeer(String peerOnion);

  Future<T> runForPeer<T>(
    String peerOnion,
    Future<T> Function() operation, {
    int maxAttempts = TorDelivery.defaultMaxAttempts,
  });

  Future<String> getProfile(
    String peerOnion, {
    Duration timeout = const Duration(seconds: 20),
    int maxAttempts = TorDelivery.defaultMaxAttempts,
  });

  Future<String> getPublic(
    String peerOnion, {
    Duration timeout = const Duration(seconds: 20),
    int maxAttempts = TorDelivery.defaultMaxAttempts,
  });

  Future<void> postMessage({
    required String peerOnion,
    required Map<String, dynamic> payload,
    Duration timeout = const Duration(seconds: 30),
  });

  Future<void> postJson({
    required String peerOnion,
    required String path,
    required Map<String, dynamic> payload,
    Duration timeout = const Duration(seconds: 30),
  });

  void dispose();
}
