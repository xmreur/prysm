import 'dart:typed_data';

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
  });
}
