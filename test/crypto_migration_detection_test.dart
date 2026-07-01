import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/crypto/constants.dart';
import 'package:prysm/crypto/key_store.dart';

void main() {
  setUp(() {
    CryptoKeyStore.setUseInMemoryStorageOnly(true);
    CryptoKeyStore.resetInMemoryStorageForTest();
  });

  tearDown(() {
    CryptoKeyStore.setUseInMemoryStorageOnly(false);
  });

  group('needsCryptoMigration', () {
    test('fresh install does not require migration', () async {
      expect(await CryptoKeyStore.needsCryptoMigration(), isFalse);
    });

    test('legacy RSA storage requires migration', () async {
      await CryptoKeyStore.write('ENCRYPTED_PRIVATE_KEY', 'legacy');
      expect(await CryptoKeyStore.needsCryptoMigration(), isTrue);
    });

    test('v2 keys without generation marker backfill and skip migration', () async {
      await CryptoKeyStore.write(
        CryptoKeyStore.encryptedIdentityKey,
        'enc',
      );
      await CryptoKeyStore.write(
        CryptoKeyStore.passphraseSaltKey,
        'salt',
      );

      expect(await CryptoKeyStore.needsCryptoMigration(), isFalse);
      expect(
        await CryptoKeyStore.cryptoGeneration(),
        CryptoConstants.cryptoGeneration,
      );
    });

    test('current generation marker skips migration', () async {
      await CryptoKeyStore.setCryptoGeneration(CryptoConstants.cryptoGeneration);
      expect(await CryptoKeyStore.needsCryptoMigration(), isFalse);
    });
  });
}
