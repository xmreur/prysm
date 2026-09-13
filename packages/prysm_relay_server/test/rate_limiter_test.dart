library;

import 'package:prysm_relay_server/prysm_relay_server.dart';
import 'package:test/test.dart';

void main() {
  var now = DateTime.utc(2026, 1, 1);

  setUp(() => now = DateTime.utc(2026, 1, 1));

  RelayRateLimiter limiter({int maxPerKey = 2, int maxKeys = 4}) =>
      RelayRateLimiter(
        window: const Duration(minutes: 1),
        maxPerKey: maxPerKey,
        maxKeys: maxKeys,
        now: () => now,
      );

  test('counts per key inside the window and resets after it', () {
    final l = limiter();
    expect(l.allow('a'), isTrue);
    expect(l.allow('a'), isTrue);
    expect(l.allow('a'), isFalse);
    expect(l.allow('b'), isTrue);
    now = now.add(const Duration(minutes: 2));
    expect(l.allow('a'), isTrue);
  });

  test('rotating keys cannot grow the map past maxKeys', () {
    final l = limiter(maxKeys: 4);
    for (var i = 0; i < 1000; i++) {
      l.allow('key-$i');
    }
    expect(l.trackedKeys, lessThanOrEqualTo(4));
  });

  test('a key whose window expired is replaced, not accumulated', () {
    final l = limiter(maxKeys: 4);
    for (var i = 0; i < 4; i++) {
      expect(l.allow('key-$i'), isTrue);
    }
    // Full: a fresh key is refused rather than evicting a live window.
    expect(l.allow('key-4'), isFalse);
    // Once the windows are over, the slots come back.
    now = now.add(const Duration(minutes: 2));
    expect(l.allow('key-4'), isTrue);
    expect(l.trackedKeys, 1);
  });
}
