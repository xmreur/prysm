import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/crypto/crypto.dart';
import 'package:prysm/models/unlock_type.dart';

void main() {
  group('CryptoKdf', () {
    test('deriveKeyFromPassphrase is deterministic', () {
      final salt = CryptoKdf.randomBytes(16);
      final a = CryptoKdf.deriveKeyFromPassphrase('test-passphrase-12', salt);
      final b = CryptoKdf.deriveKeyFromPassphrase('test-passphrase-12', salt);
      expect(a, equals(b));
    });

    test('constantTimeEquals works', () {
      expect(CryptoKdf.constantTimeEquals([1, 2], [1, 2]), isTrue);
      expect(CryptoKdf.constantTimeEquals([1, 2], [1, 3]), isFalse);
    });
  });

  group('CryptoAead', () {
    test('AES-GCM round trip', () async {
      final plain = Uint8List.fromList([1, 2, 3, 4, 5]);
      final enc = await CryptoAead.encryptAesGcm(plain);
      final key = await CryptoAead.secretKeyFromBytes(
        CryptoKdf.randomBytes(32),
      );
      // Re-encrypt with known key for decrypt test
      final enc2 = await CryptoAead.encryptAesGcm(plain, key: key);
      final dec = await CryptoAead.decryptAesGcm(
        ciphertextWithTag: enc2.ciphertext,
        key: key,
        nonce: enc2.nonce,
      );
      expect(dec, plain);
      expect(enc.nonce.length, 12);
    });

    test('ChaCha20-Poly1305 round trip', () async {
      final key = await CryptoAead.secretKeyFromBytes(
        CryptoKdf.randomBytes(32),
      );
      final plain = Uint8List.fromList([9, 8, 7, 6]);
      final enc = await CryptoAead.encryptChaCha(plain, key: key);
      final dec = await CryptoAead.decryptChaCha(
        ciphertextWithTag: enc.ciphertext,
        key: key,
        nonce: enc.nonce,
      );
      expect(dec, plain);
    });
  });

  group('IdentityKeyPair', () {
    test('generate and export public json', () async {
      final id = await IdentityKeyPair.generate();
      final json = await id.toPublicJson();
      expect(json['crypto'], 'v2');
      expect(json['signPublic'], isNotEmpty);
      expect(json['agreePublic'], isNotEmpty);
      expect(json['fingerprint'], isNotEmpty);
    });

    test('private json round trip', () async {
      final id = await IdentityKeyPair.generate();
      final privateJson = await id.toPrivateJson();
      final restored = await IdentityKeyPair.fromPrivateJson(privateJson);
      final pubA = await id.signPublicKeyBytes();
      final pubB = await restored.signPublicKeyBytes();
      expect(pubA, pubB);
    });

    test('rejects mismatched wire fingerprint', () async {
      final id = await IdentityKeyPair.generate();
      final json = await id.toPublicJson();
      json['fingerprint'] = 'deadbeef';
      expect(
        () => IdentityKeyPair.parsePublicJson(json),
        throwsFormatException,
      );
    });
  });

  group('PrekeyBundle', () {
    test('parseVerified rejects tampered signature', () async {
      final id = await IdentityKeyPair.generate();
      final pub = IdentityPublicKeys(
        signPublic: await id.signPublicKey,
        agreePublic: await id.agreePublicKey,
        fingerprint: 'fp',
      );
      final bundle = await PrekeyBundle.generate(id, persist: false);
      final json = bundle.toJson();
      json['signedPreKeySig'] = base64Encode(List.filled(64, 1));
      expect(
        () => PrekeyBundle.parseVerified(json, pub),
        throwsFormatException,
      );
    });
  });

  group('CryptoKeyStore', () {
    test('passphrase validation', () {
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

    test('encrypt and decrypt identity', () async {
      final id = await IdentityKeyPair.generate();
      const passphrase = 'my-secure-passphrase';
      final enc = await CryptoKeyStore.testEncryptIdentity(
        passphrase: passphrase,
        identity: id,
      );
      final dec = await CryptoKeyStore.testDecryptIdentity(
        passphrase: passphrase,
        encrypted: enc['encrypted']!,
        saltB64: enc['saltB64']!,
      );
      expect(dec, isNotNull);
      final a = await id.agreePublicKeyBytes();
      final b = await dec!.agreePublicKeyBytes();
      expect(a, b);
    });
  });

  group('CryptoWire', () {
    test('1:1 text round trip', () async {
      final alice = await IdentityKeyPair.generate();
      final bob = await IdentityKeyPair.generate();
      final bobPub = await bob.agreePublicKey;

      final wire = await CryptoWire.encryptTextForPeer(
        'hello prysm',
        alice,
        bobPub,
      );
      expect(CryptoEnvelope.isV2(wire), isTrue);

      final plain = await CryptoWire.decryptTextFromPeer(
        wire,
        bob,
        await alice.agreePublicKey,
      );
      expect(plain, 'hello prysm');
    });

    test('file round trip', () async {
      final alice = await IdentityKeyPair.generate();
      final bob = await IdentityKeyPair.generate();
      final bobPub = await bob.agreePublicKey;
      final bytes = Uint8List.fromList([10, 20, 30, 40, 50]);

      final payloads = await CryptoWire.encryptFile(bytes, alice, bobPub);
      final dec = await CryptoWire.decryptFile(payloads.peerPayload, bob);
      expect(dec, bytes);
    });
  });

  group('GroupCryptoV2', () {
    test('group text round trip', () async {
      final key = GroupCryptoV2.generateGroupKey();
      final enc = await GroupCryptoV2.encryptText(key, 'group msg');
      final dec = await GroupCryptoV2.decryptText(key, enc);
      expect(dec, 'group msg');
    });

    test('sender key rejects forged sender id', () async {
      final alice = await IdentityKeyPair.generate();
      final bob = await IdentityKeyPair.generate();
      final epochKey = GroupCryptoV2.generateGroupKey();
      const groupId = 'group-test';
      const index = 1;

      final wire = await GroupCryptoV2.encryptWithSenderKey(
        epochKey: epochKey,
        groupId: groupId,
        senderId: 'bob.onion',
        messageIndex: index,
        plaintext: 'forged',
        sender: alice,
      );

      final bobPub = IdentityPublicKeys(
        signPublic: await bob.signPublicKey,
        agreePublic: await bob.agreePublicKey,
        fingerprint: 'bob',
      );

      expect(
        () => GroupCryptoV2.decryptWithSenderKey(
          epochKey: epochKey,
          groupId: groupId,
          wire: wire,
          transportSenderId: 'alice.onion',
          senderKeys: bobPub,
        ),
        throwsArgumentError,
      );
    });

    test('sender key round trip with signature', () async {
      final alice = await IdentityKeyPair.generate();
      final epochKey = GroupCryptoV2.generateGroupKey();
      const groupId = 'group-test';
      const senderId = 'alice.onion';
      const index = 2;

      final wire = await GroupCryptoV2.encryptWithSenderKey(
        epochKey: epochKey,
        groupId: groupId,
        senderId: senderId,
        messageIndex: index,
        plaintext: 'hello group',
        sender: alice,
      );

      final alicePub = IdentityPublicKeys(
        signPublic: await alice.signPublicKey,
        agreePublic: await alice.agreePublicKey,
        fingerprint: 'alice',
      );

      final plain = await GroupCryptoV2.decryptWithSenderKey(
        epochKey: epochKey,
        groupId: groupId,
        wire: wire,
        transportSenderId: senderId,
        senderKeys: alicePub,
      );
      expect(plain, 'hello group');
    });
  });
}
