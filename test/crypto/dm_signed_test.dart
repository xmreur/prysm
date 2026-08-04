import 'dart:typed_data';

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
  group('dm-signed-1', () {
    test('signed 1:1 text round trip', () async {
      final alice = await IdentityKeyPair.generate();
      final bob = await IdentityKeyPair.generate();
      final bobPub = await bob.agreePublicKey;
      final alicePub = await _publicKeys(alice);

      final wire = await CryptoWire.encryptSignedTextForPeer(
        'hello signed',
        alice,
        bobPub,
      );
      expect(CryptoEnvelope.isV2(wire), isTrue);
      final parsed = CryptoEnvelope.tryParse(wire)!;
      expect(parsed['scheme'], CryptoConstants.schemeDmSigned1);

      final plain = await CryptoWire.decryptSignedTextFromPeer(
        wire,
        bob,
        alicePub,
      );
      expect(plain, 'hello signed');
    });

    test('rejects forged sender signature', () async {
      final alice = await IdentityKeyPair.generate();
      final bob = await IdentityKeyPair.generate();
      final attacker = await IdentityKeyPair.generate();
      final bobPub = await bob.agreePublicKey;
      final alicePub = await _publicKeys(alice);

      final wire = await CryptoWire.encryptSignedTextForPeer(
        'forged',
        attacker,
        bobPub,
      );

      expect(
        () => CryptoWire.decryptSignedTextFromPeer(wire, bob, alicePub),
        throwsFormatException,
      );
    });

    test('rejects unsigned dh-aead-1 without legacy flag', () async {
      final alice = await IdentityKeyPair.generate();
      final bob = await IdentityKeyPair.generate();
      final alicePub = await _publicKeys(alice);
      final bobPub = await bob.agreePublicKey;

      final wire = await CryptoWire.encryptTextForPeer('legacy', alice, bobPub);

      expect(
        () => RatchetService.instance.decryptText(
          peerId: 'alice.onion',
          wire: wire,
          local: bob,
          peer: alicePub,
          allowLegacyUnsignedDhAead: false,
        ),
        throwsFormatException,
      );
    });

    test('allows legacy unsigned dh-aead-1 for stored history', () async {
      final alice = await IdentityKeyPair.generate();
      final bob = await IdentityKeyPair.generate();
      final alicePub = await _publicKeys(alice);
      final bobPub = await bob.agreePublicKey;

      final wire = await CryptoWire.encryptTextForPeer('legacy', alice, bobPub);

      final plain = await RatchetService.instance.decryptText(
        peerId: 'alice.onion',
        wire: wire,
        local: bob,
        peer: alicePub,
        allowLegacyUnsignedDhAead: true,
      );
      expect(plain, 'legacy');
    });

    test('encryptBytesForPeer produces dm-signed-1', () async {
      final alice = await IdentityKeyPair.generate();
      final bob = await IdentityKeyPair.generate();
      final keyManager = KeyManager.fromIdentity(alice);
      final bobPub = await _publicKeys(bob);

      final wire = await keyManager.encryptBytesForPeer(
        Uint8List.fromList([1, 2, 3]),
        bobPub,
      );
      final parsed = CryptoEnvelope.tryParse(wire)!;
      expect(parsed['scheme'], CryptoConstants.schemeDmSigned1);
    });
  });
}
