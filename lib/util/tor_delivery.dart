import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:prysm/util/tor_service.dart';

/// Shared Tor outbound retry with optional NEWNYM between attempts.
class TorDelivery {
  TorDelivery._();

  static TorManager? _torManager;
  static DateTime? _lastNewnymAt;
  static Future<void>? _refreshInFlight;

  static const Duration _newnymMinInterval = Duration(seconds: 10);
  static const Duration _circuitNewnymMinInterval = Duration(seconds: 5);
  static const int defaultMaxAttempts = 3;
  static const List<Duration> _retryDelays = [
    Duration(milliseconds: 800),
    Duration(seconds: 2),
    Duration(seconds: 3),
  ];

  static void configure(TorManager manager) {
    _torManager = manager;
  }

  static String _errorText(Object error) => error.toString().toLowerCase();

  /// Transient Tor/SOCKS failures worth retrying (peer may still be online).
  static bool isRetryableError(Object error) {
    if (error is TimeoutException) return true;
    final message = _errorText(error);
    return message.contains('ttlexpired') ||
        message.contains('hostunreachable') ||
        message.contains('networkunreachable') ||
        message.contains('connection refused') ||
        message.contains('connectionrefused') ||
        message.contains('connection reset') ||
        message.contains('socketexception') ||
        message.contains('failed host lookup') ||
        message.contains('connection closed') ||
        message.contains('handshake') ||
        message.contains('socks') ||
        message.contains('general socks server failure');
  }

  /// Circuit-level failures where a fresh path often fixes delivery.
  static bool isCircuitError(Object error) {
    if (error is HttpException) return true;
    final message = _errorText(error);
    return message.contains('hostunreachable') ||
        message.contains('networkunreachable') ||
        message.contains('ttlexpired') ||
        message.contains('connection closed while receiving') ||
        message.contains('general socks server failure');
  }

  static Future<void> _maybeRefreshCircuit({
    required bool circuitError,
    bool force = false,
  }) async {
    final manager = _torManager;
    if (manager == null) return;

    final now = DateTime.now();
    final minInterval =
        circuitError ? _circuitNewnymMinInterval : _newnymMinInterval;
    if (!force &&
        _lastNewnymAt != null &&
        now.difference(_lastNewnymAt!) < minInterval) {
      return;
    }

    if (_refreshInFlight != null) {
      return _refreshInFlight;
    }

    _refreshInFlight = () async {
      try {
        final ok = await manager.refreshCircuit();
        if (ok) {
          _lastNewnymAt = DateTime.now();
          await Future.delayed(
            circuitError
                ? const Duration(milliseconds: 1500)
                : const Duration(seconds: 1),
          );
        }
      } finally {
        _refreshInFlight = null;
      }
    }();

    return _refreshInFlight;
  }

  static Future<T> withTorRetry<T>({
    required Future<T> Function() attempt,
    int maxAttempts = defaultMaxAttempts,
    bool Function(Object error)? isRetryable,
  }) async {
    final retryable = isRetryable ?? isRetryableError;
    Object? lastError;

    for (var i = 0; i < maxAttempts; i++) {
      try {
        return await attempt();
      } catch (e, stack) {
        lastError = e;
        final canRetry = i < maxAttempts - 1 && retryable(e);
        if (!canRetry) {
          Error.throwWithStackTrace(e, stack);
        }
        final circuit = isCircuitError(e);
        // One forced NEWNYM per operation; further retries wait for interval.
        await _maybeRefreshCircuit(circuitError: circuit, force: circuit && i == 0);
        final delay = _retryDelays[min(i, _retryDelays.length - 1)];
        await Future.delayed(delay);
      }
    }

    throw lastError ?? Exception('Tor delivery failed');
  }

  @visibleForTesting
  static void resetForTest() {
    _torManager = null;
    _lastNewnymAt = null;
    _refreshInFlight = null;
  }

  @visibleForTesting
  static void setLastNewnymForTest(DateTime? value) {
    _lastNewnymAt = value;
  }
}
