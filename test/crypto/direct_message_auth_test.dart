import 'dart:convert';

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
  group('DirectMessageAuth', () {
    test('locked path accepts valid dm-signed-1 as pendingAuth', () async {
      final alice = await IdentityKeyPair.generate();
      final bob = await IdentityKeyPair.generate();
      final alicePub = await _publicKeys(alice);
      final bobPub = await bob.agreePublicKey;

      final wire = await CryptoWire.encryptSignedTextForPeer(
        'locked pending',
        alice,
        bobPub,
      );

      final outcome = await DirectMessageAuth.authenticateInboundDirect(
        senderId: 'alice.onion',
        wire: wire,
        type: 'text',
        localUserId: 'bob.onion',
        keyManager: KeyManager(),
        resolveIdentity: (_) async => alicePub,
        fullDecrypt: false,
      );
      expect(outcome, DirectAuthOutcome.pendingAuth);
    });

    test('locked path rejects forged dm-signed-1 when identity known', () async {
      final alice = await IdentityKeyPair.generate();
      final bob = await IdentityKeyPair.generate();
      final attacker = await IdentityKeyPair.generate();
      final alicePub = await _publicKeys(alice);
      final bobPub = await bob.agreePublicKey;

      final wire = await CryptoWire.encryptSignedTextForPeer(
        'forged',
        attacker,
        bobPub,
      );

      final outcome = await DirectMessageAuth.authenticateInboundDirect(
        senderId: 'alice.onion',
        wire: wire,
        type: 'text',
        localUserId: 'bob.onion',
        keyManager: KeyManager(),
        resolveIdentity: (_) async => alicePub,
        fullDecrypt: false,
      );
      expect(outcome, DirectAuthOutcome.rejected);
    });

    test('ratchet while locked stays pendingAuth', () async {
      final alicePub = await _publicKeys(await IdentityKeyPair.generate());
      final wire = jsonEncode({
        'crypto': CryptoConstants.cryptoVersion,
        'scheme': CryptoConstants.schemeRatchet1,
        'nonce': 'abc',
        'ciphertext': 'def',
        'counter': 0,
      });

      final outcome = await DirectMessageAuth.authenticateInboundDirect(
        senderId: 'alice.onion',
        wire: wire,
        type: 'text',
        localUserId: 'bob.onion',
        keyManager: KeyManager(),
        resolveIdentity: (_) async => alicePub,
        fullDecrypt: false,
      );
      expect(outcome, DirectAuthOutcome.pendingAuth);
    });

    test('unlocked path accepts valid dm-signed-1', () async {
      final alice = await IdentityKeyPair.generate();
      final bob = await IdentityKeyPair.generate();
      final alicePub = await _publicKeys(alice);
      final bobPub = await bob.agreePublicKey;
      final keyManager = KeyManager.fromIdentity(bob);

      final wire = await CryptoWire.encryptSignedTextForPeer(
        'hello',
        alice,
        bobPub,
      );

      final outcome = await DirectMessageAuth.authenticateInboundDirect(
        senderId: 'alice.onion',
        wire: wire,
        type: 'text',
        localUserId: 'bob.onion',
        keyManager: keyManager,
        resolveIdentity: (_) async => alicePub,
        fullDecrypt: true,
      );
      expect(outcome, DirectAuthOutcome.accepted);
    });
  });
}
