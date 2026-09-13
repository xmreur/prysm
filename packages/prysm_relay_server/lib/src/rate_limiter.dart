/// Fixed-window limiter modelled on the app's `InboundRateLimiter`: one
/// per-key window, a hard cap on how many keys are tracked at once, and no
/// full-map work on the happy path. Keys are `deposit:<hex>`, `owner:<fpr>`
/// and `pair:<fpr>` — never an IP, because every connection arrives from the
/// local Tor. [now] is injected so tests are deterministic.
library;

class RelayRateLimiter {
  RelayRateLimiter({
    required this.window,
    required this.maxPerKey,
    this.maxKeys = 4096,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final Duration window;
  final int maxPerKey;

  /// Ceiling on tracked keys. `pair:<fpr>` is reached with nothing but a
  /// self-signed request, so an attacker rotating identities used to add a map
  /// entry per request for a whole hour — and every [allow] scanned the map it
  /// was growing.
  // ponytail: one flat cap and a scan only when it is hit; per-prefix caps or
  // an LRU only if a real deployment shows this refuses honest callers.
  final int maxKeys;

  final DateTime Function() _now;

  final Map<String, _Window> _windows = {};

  bool allow(String key) {
    final now = _now();
    final existing = _windows[key];
    if (existing != null) {
      if (now.difference(existing.startedAt) < window) {
        if (existing.count >= maxPerKey) return false;
        existing.count++;
        return true;
      }
      _windows.remove(key);
    }
    if (_windows.length >= maxKeys) {
      _windows.removeWhere((_, w) => now.difference(w.startedAt) >= window);
      // Still full: every slot is a live window, so this is a flood. Refusing
      // is `rate_limited`, which is retryable — the alternative (evicting a
      // live window) would hand the attacker a counter reset.
      if (_windows.length >= maxKeys) return false;
    }
    _windows[key] = _Window(now)..count = 1;
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
