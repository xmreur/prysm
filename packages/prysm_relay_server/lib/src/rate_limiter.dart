/// Fixed-window limiter modelled on the app's `InboundRateLimiter`: one
/// per-key window, stale windows pruned on every [allow] so rotating keys
/// cannot grow the map. Keys are `deposit:<hex>` and `owner:<fpr>` — never an
/// IP, because every connection arrives from the local Tor. [now] is injected
/// so tests are deterministic.
library;

class RelayRateLimiter {
  RelayRateLimiter({
    required this.window,
    required this.maxPerKey,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final Duration window;
  final int maxPerKey;
  final DateTime Function() _now;

  final Map<String, _Window> _windows = {};

  bool allow(String key) {
    final now = _now();
    _windows.removeWhere((_, w) => now.difference(w.startedAt) >= window);
    final w = _windows.putIfAbsent(key, () => _Window(now));
    if (w.count >= maxPerKey) return false;
    w.count++;
    return true;
  }

  int get trackedKeys => _windows.length;

  void reset() => _windows.clear();
}

class _Window {
  _Window(this.startedAt);

  final DateTime startedAt;
  int count = 0;
}
