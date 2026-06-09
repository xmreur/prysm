import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:prysm/util/tor_service.dart';

class TorSupervisorEvaluation {
  final TorConnectionEvaluation connection;
  final bool autoRestartScheduled;

  const TorSupervisorEvaluation({
    required this.connection,
    this.autoRestartScheduled = false,
  });
}

enum TorConnectionEvaluation {
  connected,
  disconnected,
  needsAttention,
}

/// Desktop Tor supervision: health evaluation, auto-restart with backoff.
class TorSupervisor {
  TorSupervisor({
    required this.torManager,
    required this.isTorStopped,
    required this.isRestartInProgress,
    required this.performRestart,
    this.enabled = true,
  }) {
    torManager.onDesktopProcessExited = _onDesktopProcessExited;
  }

  final TorManager torManager;
  final bool Function() isTorStopped;
  final bool Function() isRestartInProgress;
  final Future<void> Function({bool userInitiated}) performRestart;
  final bool enabled;

  static const int consecutiveFailureThreshold = 2;
  static const Duration minAutoRestartInterval = Duration(seconds: 60);
  static const Duration autoRestartWindow = Duration(minutes: 30);
  static const int maxAutoRestartsPerWindow = 3;

  int _consecutiveFailures = 0;
  DateTime? _lastFailureAt;
  DateTime? _lastAutoRestartAt;
  final List<DateTime> _autoRestartTimes = [];
  bool _needsAttention = false;
  bool _autoRestartScheduled = false;
  String? lastHealthFailureReason;
  int autoRestartCount = 0;

  bool get needsAttention => _needsAttention;

  List<String> get recentStderrLines => torManager.recentStderrLines;

  void dispose() {
    torManager.onDesktopProcessExited = null;
  }

  void _onDesktopProcessExited(int exitCode) {
    if (!enabled || Platform.isAndroid || Platform.isIOS) return;
    lastHealthFailureReason = 'Tor process exited ($exitCode)';
    _consecutiveFailures = consecutiveFailureThreshold;
    unawaited(_maybeAutoRestart());
  }

  Future<TorSupervisorEvaluation> evaluateHealth() async {
    if (!enabled || isTorStopped() || isRestartInProgress()) {
      return TorSupervisorEvaluation(
        connection: TorConnectionEvaluation.disconnected,
      );
    }

    final status = await torManager.getHealthStatus();
    if (status.ok) {
      _consecutiveFailures = 0;
      _lastFailureAt = null;
      _needsAttention = false;
      lastHealthFailureReason = null;
      return const TorSupervisorEvaluation(
        connection: TorConnectionEvaluation.connected,
      );
    }

    lastHealthFailureReason = status.reason;
    final now = DateTime.now();
    final bootstrapGrace = status.reason != null &&
        status.reason!.contains('bootstrap incomplete') &&
        torManager.lastStartAt != null &&
        now.difference(torManager.lastStartAt!) <
            const Duration(seconds: 60);
    if (bootstrapGrace) {
      return const TorSupervisorEvaluation(
        connection: TorConnectionEvaluation.disconnected,
      );
    }

    if (_lastFailureAt != null &&
        now.difference(_lastFailureAt!) <
            const Duration(seconds: 5)) {
      // Ignore rapid duplicate failures from the same poll window.
    } else {
      _consecutiveFailures++;
      _lastFailureAt = now;
    }

    if (_needsAttention) {
      return const TorSupervisorEvaluation(
        connection: TorConnectionEvaluation.needsAttention,
      );
    }

    if (_consecutiveFailures >= consecutiveFailureThreshold) {
      await _maybeAutoRestart();
    }

    return TorSupervisorEvaluation(
      connection: TorConnectionEvaluation.disconnected,
      autoRestartScheduled: _autoRestartScheduled,
    );
  }

  Future<void> restartTor({bool userInitiated = false}) {
    return _runRestart(userInitiated: userInitiated);
  }

  Future<void> _maybeAutoRestart() async {
    if (!enabled || Platform.isAndroid || Platform.isIOS) return;
    if (isTorStopped() || isRestartInProgress()) return;
    if (_needsAttention) return;

    final now = DateTime.now();
    _autoRestartTimes.removeWhere(
      (t) => now.difference(t) > autoRestartWindow,
    );
    if (_autoRestartTimes.length >= maxAutoRestartsPerWindow) {
      _needsAttention = true;
      return;
    }
    if (_lastAutoRestartAt != null &&
        now.difference(_lastAutoRestartAt!) < minAutoRestartInterval) {
      return;
    }

    await _runRestart(userInitiated: false);
  }

  Future<void> _runRestart({required bool userInitiated}) async {
    if (isRestartInProgress()) return;
    _autoRestartScheduled = true;
    try {
      await performRestart(userInitiated: userInitiated);
      if (!userInitiated) {
        final restartAt = DateTime.now();
        _lastAutoRestartAt = restartAt;
        _autoRestartTimes.add(restartAt);
        autoRestartCount++;
      }
      _consecutiveFailures = 0;
      _needsAttention = false;
    } finally {
      _autoRestartScheduled = false;
    }
  }

  @visibleForTesting
  bool shouldAllowAutoRestart({
    required DateTime now,
    required List<DateTime> recentRestarts,
    DateTime? lastRestart,
  }) {
    final windowed = recentRestarts
        .where((t) => now.difference(t) <= autoRestartWindow)
        .length;
    if (windowed >= maxAutoRestartsPerWindow) return false;
    if (lastRestart != null &&
        now.difference(lastRestart) < minAutoRestartInterval) {
      return false;
    }
    return true;
  }
}
