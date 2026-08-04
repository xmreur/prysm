import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/crypto/crypto.dart';
import 'package:prysm/util/key_manager.dart';

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

void main() {
  group('Wire -2 security', () {
    test('dm-signed-2 round trip with header AAD', () async {
      final alice = await IdentityKeyPair.generate();
      final bob = await IdentityKeyPair.generate();
      final bobPub = await bob.agreePublicKey;
      final alicePub = await _publicKeys(alice);

      final wire = await CryptoWire.encryptSignedTextForPeer(
        'signed v2',
        alice,
        bobPub,
      );
      final parsed = CryptoEnvelope.tryParse(wire)!;
      expect(parsed['scheme'], CryptoConstants.schemeDmSigned2);

      final plain = await CryptoWire.decryptSignedTextFromPeer(
        wire,
        bob,
        alicePub,
      );
      expect(plain, 'signed v2');
    });

    test('dm-signed-1 legacy round trip still passes', () async {
      final alice = await IdentityKeyPair.generate();
      final bob = await IdentityKeyPair.generate();
      final alicePub = await _publicKeys(alice);
      final bobPub = await bob.agreePublicKey;

      final legacyWire = jsonEncode({
        'crypto': CryptoConstants.cryptoVersion,
        'scheme': CryptoConstants.schemeDmSigned1,
        'alg': 'aes-gcm',
        'ephemeralPub': 'legacy',
        'nonce': 'legacy',
        'ciphertext': 'legacy',
        'sig': base64Encode(List.filled(64, 1)),
      });
      expect(
        () => CryptoWire.decryptSignedFromPeer(legacyWire, bob, alicePub),
        throwsFormatException,
      );

      // Build a real dm-signed-1 wire via manual encrypt (no AAD).
      final x25519 = X25519();
      final ephemeral = await x25519.newKeyPair();
      final ephemeralPublic = await ephemeral.extractPublicKey();
      final shared = await x25519.sharedSecretKey(
        keyPair: ephemeral,
        remotePublicKey: bobPub,
      );
      final sharedBytes = await shared.extractBytes();
      final aeadKey = await CryptoKdf.hkdf(
        sharedSecret: sharedBytes,
        info: utf8.encode(CryptoConstants.hkdfInfoDhAead),
        salt: ephemeralPublic.bytes,
      );
      final enc = await CryptoAead.encryptAesGcm(
        utf8.encode('legacy signed'),
        key: aeadKey,
      );
      final ephemeralPubB64 = base64Encode(ephemeralPublic.bytes);
      final nonceB64 = base64Encode(enc.nonce);
      final ciphertextB64 = base64Encode(enc.ciphertext);
      final signPayload = utf8.encode(
        '$ephemeralPubB64|$nonceB64|$ciphertextB64',
      );
      final signature = await alice.sign(signPayload);
      final wire = CryptoEnvelope.encode(
        CryptoEnvelope.dmSigned1(
          ephemeralPublic: Uint8List.fromList(ephemeralPublic.bytes),
          ciphertext: enc.ciphertext,
          nonce: enc.nonce,
          signature: signature.bytes,
        ),
      );

      final plain = await CryptoWire.decryptSignedTextFromPeer(
        wire,
        bob,
        alicePub,
      );
      expect(plain, 'legacy signed');
    });

    test('signature replay fails when scheme relabeled', () async {
      final alice = await IdentityKeyPair.generate();
      final bob = await IdentityKeyPair.generate();
      final bobPub = await bob.agreePublicKey;
      final alicePub = await _publicKeys(alice);

      final wire = await CryptoWire.encryptSignedTextForPeer(
        'replay test',
        alice,
        bobPub,
      );
      final envelope = CryptoEnvelope.tryParse(wire)!;
      envelope['scheme'] = CryptoConstants.schemeDmSigned1;
      final relabeled = CryptoEnvelope.encode(envelope);

      expect(
        () => CryptoWire.decryptSignedFromPeer(relabeled, bob, alicePub),
        throwsFormatException,
      );
    });

    test('encryptFile self payload round-trips with dh-aead-2 wrap', () async {
      final alice = await IdentityKeyPair.generate();
      final bob = await IdentityKeyPair.generate();
      final bobPub = await bob.agreePublicKey;
      final bytes = Uint8List.fromList([1, 2, 3, 4, 5]);

      final payloads = await CryptoWire.encryptFile(bytes, alice, bobPub);
      final selfEnvelope = CryptoEnvelope.tryParse(payloads.selfPayload)!;
      final wrapped = selfEnvelope['wrappedKey'] as Map<String, dynamic>;
      expect(wrapped['scheme'], CryptoConstants.schemeDhAead2);

      final dec = await CryptoWire.decryptFile(payloads.selfPayload, alice);
      expect(dec, bytes);
    });

    test('legacy wrap map without scheme still unwraps as dh-aead-1', () async {
      final bob = await IdentityKeyPair.generate();
      final bobPub = await bob.agreePublicKey;

      final x25519 = X25519();
      final ephemeral = await x25519.newKeyPair();
      final ephemeralPublic = await ephemeral.extractPublicKey();
      final shared = await x25519.sharedSecretKey(
        keyPair: ephemeral,
        remotePublicKey: bobPub,
      );
      final sharedBytes = await shared.extractBytes();
      final aeadKey = await CryptoKdf.hkdf(
        sharedSecret: sharedBytes,
        info: utf8.encode(CryptoConstants.hkdfInfoDhAead),
        salt: ephemeralPublic.bytes,
      );
      final keyBytes = CryptoKdf.randomBytes(32);
      final enc = await CryptoAead.encryptAesGcm(keyBytes, key: aeadKey);
      final legacyWrap = {
        'ephemeralPub': base64Encode(ephemeralPublic.bytes),
        'nonce': base64Encode(enc.nonce),
        'ciphertext': base64Encode(enc.ciphertext),
      };

      final unwrapped = await CryptoWire.unwrapKeyFromPeer(legacyWrap, bob);
      expect(unwrapped, keyBytes);
    });

    test('inbound dh-aead-2 from known peer is rejected', () async {
      final alice = await IdentityKeyPair.generate();
      final bob = await IdentityKeyPair.generate();
      final alicePub = await _publicKeys(alice);
      final bobPub = await bob.agreePublicKey;

      final wire = await CryptoWire.encryptTextForPeer('unsigned', alice, bobPub);

      final outcome = await DirectMessageAuth.authenticateInboundDirect(
        senderId: 'alice.onion',
        wire: wire,
        type: 'text',
        localUserId: 'bob.onion',
        keyManager: KeyManager.fromIdentity(bob),
        resolveIdentity: (_) async => alicePub,
        fullDecrypt: false,
      );
      expect(outcome, DirectAuthOutcome.rejected);
    });
  });
}
