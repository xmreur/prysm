import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/crypto/key_store.dart';
import 'package:prysm/models/unlock_type.dart';

void main() {
  group('isValidUnlockSecret', () {
    test('pin accepts six digits only', () {
      expect(CryptoKeyStore.isValidUnlockSecret('123456', UnlockType.pin), isTrue);
      expect(CryptoKeyStore.isValidUnlockSecret('12345', UnlockType.pin), isFalse);
      expect(CryptoKeyStore.isValidUnlockSecret('1234567', UnlockType.pin), isFalse);
      expect(CryptoKeyStore.isValidUnlockSecret('12a456', UnlockType.pin), isFalse);
    });

    test('passphrase requires twelve characters', () {
      expect(
        CryptoKeyStore.isValidUnlockSecret('short', UnlockType.passphrase),
        isFalse,
      );
      expect(
        CryptoKeyStore.isValidUnlockSecret(
          'long-enough-pass',
          UnlockType.passphrase,
        ),
        isTrue,
      );
    });
  });
}
