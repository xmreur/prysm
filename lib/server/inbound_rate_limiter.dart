import 'package:flutter/foundation.dart';

import 'package:prysm/server/inbound_limits.dart';

/// Fixed-window request counter for the inbound HTTP endpoints.
///
/// One per-key window plus one shared global window, both reset when the
/// current window elapses. No timers: [now] is injected so tests are
/// deterministic. Stale per-key windows are pruned on every [allow] call so a
/// peer rotating key values cannot grow the map without bound.
class InboundRateLimiter {
  InboundRateLimiter({
    Duration window = InboundLimits.rateWindow,
    int maxPerKey = InboundLimits.maxRequestsPerSenderPerWindow,
    int maxGlobal = InboundLimits.maxRequestsPerWindow,
    DateTime Function()? now,
  })  : _window = window,
        _maxPerKey = maxPerKey,
        _maxGlobal = maxGlobal,
        _now = now ?? DateTime.now;

  final Duration _window;
  final int _maxPerKey;
  final int _maxGlobal;
  final DateTime Function() _now;

  /// Reserved key for the server-wide gate: probes with this key exercise
  /// only the global window and never consume a per-key quota, so the global
  /// cap ([InboundLimits.maxRequestsPerWindow]) is what actually binds.
  static const String globalKey = '*';

  final Map<String, _Window> _windows = {};
  _Window? _global;

  /// Records one request for [key] and returns whether it is allowed.
  ///
  /// The shared global window is checked first; once it is exhausted every
  /// key is denied. Keys other than [globalKey] then consume their own
  /// per-key quota. Both windows reset once [InboundLimits.rateWindow]
  /// elapses from their start.
  bool allow(String key) {
    final now = _now();
    _windows.removeWhere((_, w) => now.difference(w.startedAt) >= _window);

    if (_global == null || now.difference(_global!.startedAt) >= _window) {
      _global = _Window(now);
    }
    if (_global!.count >= _maxGlobal) return false;

    if (key != globalKey) {
      final window = _windows.putIfAbsent(key, () => _Window(now));
      if (window.count >= _maxPerKey) return false;
      window.count++;
    }

    _global!.count++;
    return true;
  }

  /// Number of per-key windows currently tracked (test seam).
  @visibleForTesting
  int get trackedKeys => _windows.length;

  /// Clears all windows (test seam).
  @visibleForTesting
  void resetForTest() {
    _windows.clear();
    _global = null;
  }
}

class _Window {
  _Window(this.startedAt);

  final DateTime startedAt;
  int count = 0;
}
