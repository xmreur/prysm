import 'package:prysm/util/battery_saver_policy.dart';

/// Tracks peer online presence from chat activity and profile probes.
class PeerPresenceTracker {
  PeerPresenceTracker({DateTime Function()? now}) : _now = now ?? DateTime.now;

  final DateTime Function() _now;

  DateTime? _lastActivityAt;
  int _consecutiveProfileFailures = 0;
  bool _probeMarkedOffline = false;
  DateTime? _probeFailuresSuspendedUntil;

  static const int _hardFailureThreshold = 2;
  static const int _softFailureThreshold = 3;

  DateTime? get lastActivityAt => _lastActivityAt;

  bool get _hasRecentActivity {
    final last = _lastActivityAt;
    if (last == null) return false;
    return _now().difference(last) < BatterySaverPolicy.presenceActivityTtl();
  }

  /// `true` = online, `false` = offline, `null` = unknown / checking.
  bool? get isOnline {
    if (_hasRecentActivity) return true;
    if (_lastActivityAt != null) return false;
    if (_probeMarkedOffline) return false;
    return null;
  }

  void recordActivity([DateTime? at]) {
    _lastActivityAt = at ?? _now();
    _consecutiveProfileFailures = 0;
    _probeMarkedOffline = false;
  }

  /// While a large outbound upload is in flight the peer may be too busy to
  /// answer profile probes even though they are reachable.
  void suspendProbeFailuresFor(Duration duration) {
    final until = _now().add(duration);
    final current = _probeFailuresSuspendedUntil;
    if (current == null || until.isAfter(current)) {
      _probeFailuresSuspendedUntil = until;
    }
  }

  bool get _probeFailuresSuspended {
    final until = _probeFailuresSuspendedUntil;
    if (until == null) return false;
    if (!_now().isBefore(until)) {
      _probeFailuresSuspendedUntil = null;
      return false;
    }
    return true;
  }

  /// Records a failed profile probe. Ignored when there is recent chat activity.
  void considerProfileFailure({required bool isHardFailure}) {
    if (_hasRecentActivity || _probeFailuresSuspended) return;
    _consecutiveProfileFailures++;
    if ((isHardFailure &&
            _consecutiveProfileFailures >= _hardFailureThreshold) ||
        _consecutiveProfileFailures >= _softFailureThreshold) {
      _probeMarkedOffline = true;
    }
  }

  void reset() {
    _lastActivityAt = null;
    _consecutiveProfileFailures = 0;
    _probeMarkedOffline = false;
    _probeFailuresSuspendedUntil = null;
  }
}
