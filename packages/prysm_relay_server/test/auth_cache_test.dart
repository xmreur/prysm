library;

import 'package:prysm_relay_protocol/prysm_relay_protocol.dart';
import 'package:prysm_relay_server/prysm_relay_server.dart';
import 'package:test/test.dart';

void main() {
  final windowMs = RelayProtocol.replayWindow.inMilliseconds;

  test('a digest inside the window is a replay, outside it is not', () {
    final cache = RelayAuthCache();
    expect(cache.checkAndAdd('aa', 1000), isFalse);
    expect(cache.checkAndAdd('aa', 1000 + windowMs), isTrue);
    expect(cache.checkAndAdd('aa', 1000 + windowMs + 1), isFalse);
    expect(cache.tracked, 1);
  });

  test('rotating digests cannot grow the cache past maxEntries', () {
    final cache = RelayAuthCache(maxEntries: 8);
    // Live digests: the cache refuses rather than forgetting one.
    for (var i = 0; i < 8; i++) {
      expect(cache.checkAndAdd('d$i', 1000), isFalse);
    }
    expect(
      () => cache.checkAndAdd('d8', 1000),
      throwsA(
        isA<RelayError>().having(
          (e) => e.code,
          'code',
          RelayErrorCode.rateLimited,
        ),
      ),
    );
    expect(cache.tracked, 8);

    // Past the window the slots come back without losing protection.
    expect(cache.checkAndAdd('d8', 1000 + windowMs + 1), isFalse);
    expect(cache.tracked, 1);
  });
}
