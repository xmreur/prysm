import 'package:prysm/util/battery_saver_policy.dart';

/// Tracks peer online presence from WebSocket state and chat activity.
class PeerPresenceTracker {
  PeerPresenceTracker({DateTime Function()? now}) : _now = now ?? DateTime.now;

  final DateTime Function() _now;

  DateTime? _lastActivityAt;
  bool? _wsConnected;

  DateTime? get lastActivityAt => _lastActivityAt;

  bool get _hasRecentActivity {
    final last = _lastActivityAt;
    if (last == null) return false;
    return _now().difference(last) < BatterySaverPolicy.presenceActivityTtl();
  }

  /// `true` = online, `false` = offline, `null` = unknown / checking.
  bool? get isOnline {
    if (_wsConnected == true) return true;
    if (_hasRecentActivity) return true;
    if (_wsConnected == false) return false;
    if (_lastActivityAt != null) return false;
    return null;
  }

  void recordActivity([DateTime? at]) {
    _lastActivityAt = at ?? _now();
  }

  void recordWsConnected() {
    _wsConnected = true;
  }

  void recordWsDisconnected() {
    _wsConnected = false;
  }

  void clearWsState() {
    _wsConnected = null;
  }

  void reset() {
    _lastActivityAt = null;
    _wsConnected = null;
  }
}
