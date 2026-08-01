import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/util/version_compare.dart';

void main() {
  group('isNewerVersion', () {
    test('returns true when latest patch is newer', () {
      expect(isNewerVersion('v0.5.0', 'v0.5.1'), isTrue);
    });

    test('returns true when latest minor is newer', () {
      expect(isNewerVersion('v0.5.0', 'v0.6.0'), isTrue);
    });

    test('returns false when versions match', () {
      expect(isNewerVersion('v0.5.0', 'v0.5.0'), isFalse);
    });

    test('returns false when current is newer', () {
      expect(isNewerVersion('v0.6.0', 'v0.5.1'), isFalse);
    });

    test('handles tags without v prefix on current', () {
      expect(isNewerVersion('0.5.0', 'v0.5.1'), isTrue);
    });
  });
}
