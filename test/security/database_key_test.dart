import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/crypto/key_store.dart';

void main() {
  group('KeyStore.databaseKey', () {
    setUp(() {
      CryptoKeyStore.setUseInMemoryStorageOnly(true);
      CryptoKeyStore.resetInMemoryStorageForTest();
    });

    tearDown(() {
      CryptoKeyStore.setUseInMemoryStorageOnly(false);
    });

    test('returns a 64-character lowercase hex string', () async {
      final key = await CryptoKeyStore.databaseKey();
      // SQLCipher raw-key contract: exactly 64 lowercase hex characters, i.e.
      // 32 bytes, interpolated as PRAGMA key = "x'<hex>'".
      expect(key, matches(RegExp(r'^[0-9a-f]{64}$')));
    });

    test('returns the identical key on a second call', () async {
      final first = await CryptoKeyStore.databaseKey();
      // A second call must return the stored key, not a fresh random one —
      // otherwise every connection would use a different key and the
      // databases would be unrecoverable.
      final second = await CryptoKeyStore.databaseKey();
      expect(second, first);
    });

    test('stores the key under the literal DATABASE_KEY_V1 name', () async {
      final key = await CryptoKeyStore.databaseKey();
      final stored = await CryptoKeyStore.read(CryptoKeyStore.databaseKeyName);
      expect(stored, key);
      expect(stored, matches(RegExp(r'^[0-9a-f]{64}$')));
    });

    test('two fresh stores produce different keys', () async {
      final first = await CryptoKeyStore.databaseKey();
      CryptoKeyStore.resetInMemoryStorageForTest();
      final second = await CryptoKeyStore.databaseKey();
      // Per-installation randomness, not a constant: a fresh store must draw
      // a fresh 256-bit key.
      expect(second, isNot(first));
    });

    test('replaces a malformed stored value with a valid key', () async {
      await CryptoKeyStore.write(CryptoKeyStore.databaseKeyName, 'not-hex');
      final key = await CryptoKeyStore.databaseKey();
      expect(key, matches(RegExp(r'^[0-9a-f]{64}$')));
      final stored = await CryptoKeyStore.read(CryptoKeyStore.databaseKeyName);
      expect(stored, key);
    });

    test('replaces a too-short hex stored value with a valid key', () async {
      final short = List.filled(63, 'a').join();
      await CryptoKeyStore.write(CryptoKeyStore.databaseKeyName, short);
      final key = await CryptoKeyStore.databaseKey();
      expect(key, matches(RegExp(r'^[0-9a-f]{64}$')));
      final stored = await CryptoKeyStore.read(CryptoKeyStore.databaseKeyName);
      expect(stored, key);
    });

    test('throws StateError when the write silently falls back to memory', () async {
      // Reproduce the state a swallowed secure-storage write failure leaves
      // behind: the key sits in the in-memory fallback map while the store
      // is NOT in test-only mode. The @visibleForTesting seams can only
      // clear the map or toggle the flag, so populate it through the public
      // write() in test-only mode, then flip the flag off. 'not-hex' forces
      // the generate-and-write path (a valid hex value would be returned by
      // the early read, never reaching the write).
      CryptoKeyStore.setUseInMemoryStorageOnly(true);
      await CryptoKeyStore.write(CryptoKeyStore.databaseKeyName, 'not-hex');
      CryptoKeyStore.setUseInMemoryStorageOnly(false);

      await expectLater(
        CryptoKeyStore.databaseKey(),
        throwsStateError,
      );
    });
  });
}
