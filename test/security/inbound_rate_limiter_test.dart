import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/server/inbound_rate_limiter.dart';

void main() {
  group('InboundRateLimiter', () {
    InboundRateLimiter limiter(
      DateTime Function() now, {
      int maxPerKey = 3,
      int maxGlobal = 100,
    }) {
      return InboundRateLimiter(
        window: const Duration(seconds: 10),
        maxPerKey: maxPerKey,
        maxGlobal: maxGlobal,
        now: now,
      );
    }

    test('allows maxPerKey requests per key, then denies', () {
      var now = DateTime(2026, 1, 1, 12);
      final l = limiter(() => now);
      expect(l.allow('a'), isTrue);
      expect(l.allow('a'), isTrue);
      expect(l.allow('a'), isTrue);
      expect(l.allow('a'), isFalse);
    });

    test('same key is allowed again after the window elapses', () {
      var now = DateTime(2026, 1, 1, 12);
      final l = limiter(() => now);
      for (var i = 0; i < 3; i++) {
        expect(l.allow('a'), isTrue);
      }
      expect(l.allow('a'), isFalse);

      now = now.add(const Duration(seconds: 10));
      expect(l.allow('a'), isTrue);
    });

    test('one key exhausting its quota does not deny another key', () {
      var now = DateTime(2026, 1, 1, 12);
      final l = limiter(() => now);
      for (var i = 0; i < 3; i++) {
        expect(l.allow('a'), isTrue);
      }
      expect(l.allow('a'), isFalse);

      expect(l.allow('b'), isTrue);
    });

    test('global cap denies even a key under its own per-key quota', () {
      var now = DateTime(2026, 1, 1, 12);
      final l = limiter(() => now, maxPerKey: 100, maxGlobal: 2);
      expect(l.allow('a'), isTrue);
      expect(l.allow('b'), isTrue);
      expect(l.allow('c'), isFalse);
    });

    test('stale per-key windows are pruned once the window elapses', () {
      var now = DateTime(2026, 1, 1, 12);
      final l = limiter(() => now, maxPerKey: 100, maxGlobal: 1000);
      expect(l.allow('old-1'), isTrue);
      expect(l.allow('old-2'), isTrue);
      expect(l.allow('old-3'), isTrue);
      expect(l.trackedKeys, 3);

      // Well past the window: a fresh key must not retain the stale ones —
      // otherwise rotating senderIds would grow the map without bound.
      now = now.add(const Duration(minutes: 5));
      expect(l.allow('new-1'), isTrue);
      expect(l.trackedKeys, 1);
    });

    test('global probe key is not throttled by the per-key quota', () {
      var now = DateTime(2026, 1, 1, 12);
      final l = limiter(() => now, maxPerKey: 3, maxGlobal: 100);
      for (var i = 0; i < 3; i++) {
        expect(l.allow(InboundRateLimiter.globalKey), isTrue);
      }
      // Only maxGlobal binds the server-wide probe; the per-key quota of 3
      // must not, and the probe never creates a tracked per-key window.
      expect(l.allow(InboundRateLimiter.globalKey), isTrue);
      expect(l.trackedKeys, 0);
    });

    test('wire-derived keys are namespaced away from the reserved global probe',
        () {
      // PrysmServer prefixes every wire-supplied senderId/requester with
      // 's:', so a caller key of '*' reaches the per-key path as 's:*' and
      // can never be mistaken for the reserved global probe. The prefixed key
      // and the reserved key must be tracked separately: 's:*' is bound by
      // the per-key quota while InboundRateLimiter.globalKey stays a pure
      // global-window probe.
      var now = DateTime(2026, 1, 1, 12);
      final l = limiter(() => now, maxPerKey: 3, maxGlobal: 100);
      for (var i = 0; i < 3; i++) {
        expect(l.allow('s:*'), isTrue);
      }
      // The per-key quota now binds the caller-supplied '*'…
      expect(l.allow('s:*'), isFalse);
      // …while the reserved probe is unaffected and consumes no per-key slot.
      expect(l.allow(InboundRateLimiter.globalKey), isTrue);
      expect(l.trackedKeys, 1);
    });
  });
}
