import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/crypto/key_store.dart';

void main() {
  group('KeyStore.torControlPassword', () {
    setUp(() {
      CryptoKeyStore.setUseInMemoryStorageOnly(true);
      CryptoKeyStore.resetInMemoryStorageForTest();
    });

    tearDown(() {
      CryptoKeyStore.setUseInMemoryStorageOnly(false);
    });

    test('returns a non-empty value and persists across calls', () async {
      final first = await CryptoKeyStore.torControlPassword();
      expect(first, isNotEmpty);

      // A second call must return the stored secret, not a new one —
      // otherwise every Tor start would use a different password and the
      // control port would never authenticate.
      final second = await CryptoKeyStore.torControlPassword();
      expect(second, first);
    });

    test('value is safe to interpolate into the control protocol', () async {
      final value = await CryptoKeyStore.torControlPassword();
      // 32 random bytes, base64-url encoded without padding.
      expect(value.length, greaterThanOrEqualTo(32));
      // The value ends up inside a quoted AUTHENTICATE "..." control line and
      // in a --hash-password argv; none of these may appear in it.
      expect(value.contains('"'), isFalse);
      expect(value.contains('='), isFalse);
      expect(value.contains('\n'), isFalse);
      expect(value.contains('\r'), isFalse);
    });

    test('two fresh stores produce different values', () async {
      final first = await CryptoKeyStore.torControlPassword();
      CryptoKeyStore.resetInMemoryStorageForTest();
      final second = await CryptoKeyStore.torControlPassword();
      // Per-installation randomness, not a constant: a fresh store must draw
      // a fresh 256-bit secret.
      expect(second, isNot(first));
    });
  });
}
