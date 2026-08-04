import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/crypto/crypto.dart';

Future<IdentityPublicKeys> _publicKeys(IdentityKeyPair id) async {
  final sign = await id.signPublicKey;
  final agree = await id.agreePublicKey;
  return IdentityPublicKeys(
    signPublic: sign,
    agreePublic: agree,
    fingerprint: IdentityKeyPair.fingerprintFromPublicJson(
      await id.toPublicJson(),
    ),
  );
}

/// Pre-update signed key wrap: dm-signed-1 signature payload, no scheme field.
Future<Map<String, dynamic>> _legacySignedWrapWithoutScheme({
  required Uint8List keyBytes,
  required IdentityKeyPair sender,
  required SimplePublicKey peerAgreePublic,
}) async {
  final x25519 = X25519();
  final ephemeral = await x25519.newKeyPair();
  final ephemeralPublic = await ephemeral.extractPublicKey();
  final shared = await x25519.sharedSecretKey(
    keyPair: ephemeral,
    remotePublicKey: peerAgreePublic,
  );
  final sharedBytes = await shared.extractBytes();
  final aeadKey = await CryptoKdf.hkdf(
    sharedSecret: sharedBytes,
    info: utf8.encode(CryptoConstants.hkdfInfoDhAead),
    salt: ephemeralPublic.bytes,
  );
  final enc = await CryptoAead.encryptAesGcm(keyBytes, key: aeadKey);
  final ephemeralPubB64 = base64Encode(ephemeralPublic.bytes);
  final nonceB64 = base64Encode(enc.nonce);
  final ciphertextB64 = base64Encode(enc.ciphertext);
  final signPayload = utf8.encode(
    '$ephemeralPubB64|$nonceB64|$ciphertextB64',
  );
  final signature = await sender.sign(signPayload);
  return {
    'crypto': CryptoConstants.cryptoVersion,
    'ephemeralPub': ephemeralPubB64,
    'nonce': nonceB64,
    'ciphertext': ciphertextB64,
    'sig': base64Encode(signature.bytes),
  };
}

void main() {
  group('file-signed-1', () {
    test('peer file round trip', () async {
      final alice = await IdentityKeyPair.generate();
      final bob = await IdentityKeyPair.generate();
      final bobPub = await bob.agreePublicKey;
      final alicePub = await _publicKeys(alice);
      final bytes = Uint8List.fromList([1, 2, 3, 4, 5]);

      final payloads = await CryptoWire.encryptFile(bytes, alice, bobPub);
      final parsed = CryptoEnvelope.tryParse(payloads.peerPayload)!;
      expect(parsed['scheme'], CryptoConstants.schemeFileSigned1);

      final dec = await CryptoWire.decryptFileFromPeer(
        payloads.peerPayload,
        bob,
        alicePub,
      );
      expect(dec, bytes);
    });

    test('rejects forged signed file wrap', () async {
      final alice = await IdentityKeyPair.generate();
      final bob = await IdentityKeyPair.generate();
      final attacker = await IdentityKeyPair.generate();
      final bobPub = await bob.agreePublicKey;
      final alicePub = await _publicKeys(alice);
      final bytes = Uint8List.fromList([9, 8, 7]);

      final payloads = await CryptoWire.encryptFile(bytes, attacker, bobPub);

      expect(
        () => CryptoWire.decryptFileFromPeer(
          payloads.peerPayload,
          bob,
          alicePub,
        ),
        throwsFormatException,
      );
    });

    test('self payload remains unsigned file-aead-1', () async {
      final alice = await IdentityKeyPair.generate();
      final bob = await IdentityKeyPair.generate();
      final bobPub = await bob.agreePublicKey;
      final bytes = Uint8List.fromList([10, 20]);

      final payloads = await CryptoWire.encryptFile(bytes, alice, bobPub);
      final parsed = CryptoEnvelope.tryParse(payloads.selfPayload)!;
      expect(parsed['scheme'], CryptoConstants.schemeFileAead1);

      final dec = await CryptoWire.decryptFile(payloads.selfPayload, alice);
      expect(dec, bytes);
    });

    test('legacy signed wrap without scheme still unwraps', () async {
      final alice = await IdentityKeyPair.generate();
      final bob = await IdentityKeyPair.generate();
      final bobPub = await bob.agreePublicKey;
      final alicePub = await _publicKeys(alice);
      final keyBytes = Uint8List.fromList([11, 22, 33]);

      final legacyWrap = await _legacySignedWrapWithoutScheme(
        keyBytes: keyBytes,
        sender: alice,
        peerAgreePublic: bobPub,
      );

      final unwrapped = await CryptoWire.unwrapSignedKeyFromPeer(
        legacyWrap,
        bob,
        alicePub,
      );
      expect(unwrapped, keyBytes);
    });

    test('legacy signed file envelope without wrap scheme decrypts', () async {
      final alice = await IdentityKeyPair.generate();
      final bob = await IdentityKeyPair.generate();
      final bobPub = await bob.agreePublicKey;
      final alicePub = await _publicKeys(alice);
      final bytes = Uint8List.fromList([5, 6, 7, 8]);
      final fileKey = CryptoKdf.randomBytes(CryptoConstants.aeadKeyLength);

      final legacyWrap = await _legacySignedWrapWithoutScheme(
        keyBytes: fileKey,
        sender: alice,
        peerAgreePublic: bobPub,
      );
      final aeadKey = await CryptoAead.secretKeyFromBytes(fileKey);
      final enc = await CryptoAead.encryptAesGcm(bytes, key: aeadKey);
      final wire = CryptoEnvelope.encode(
        CryptoEnvelope.fileSigned1(
          wrappedKey: legacyWrap,
          nonce: enc.nonce,
          ciphertext: enc.ciphertext,
        ),
      );

      final dec = await CryptoWire.decryptFileFromPeer(
        wire,
        bob,
        alicePub,
      );
      expect(dec, bytes);
    });
  });
}
