import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/asymmetric/api.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/rsa_helper.dart';

void main() {
  test('re-encrypting private key PEM with new PIN changes unlock only', () {
    final pair = RSAHelper.generateKeyPair();
    final privatePem =
        RSAHelper.privateKeyToPem(pair.privateKey as RSAPrivateKey);
    const pinA = '123456';
    const pinB = '654321';

    final encA = KeyManager.testEncryptPrivateKey(
      pin: pinA,
      privatePem: privatePem,
    );

    final decryptedA = KeyManager.testDecryptPrivateKey(
      pin: pinA,
      encrypted: encA['encrypted']!,
      saltB64: encA['saltB64']!,
    );
    expect(decryptedA, privatePem);

    final encB = KeyManager.testEncryptPrivateKey(
      pin: pinB,
      privatePem: privatePem,
    );

    final decryptedB = KeyManager.testDecryptPrivateKey(
      pin: pinB,
      encrypted: encB['encrypted']!,
      saltB64: encB['saltB64']!,
    );
    expect(decryptedB, privatePem);

    final wrongPin = KeyManager.testDecryptPrivateKey(
      pin: pinA,
      encrypted: encB['encrypted']!,
      saltB64: encB['saltB64']!,
    );
    expect(wrongPin, isNull);
  });

  test('changePin rejects invalid new PIN format', () async {
    final keyManager = KeyManager();
    expect(
      await keyManager.changePin(currentPin: '123456', newPin: '12345'),
      false,
    );
    expect(
      await keyManager.changePin(currentPin: '123456', newPin: 'abcdef'),
      false,
    );
  });
}
