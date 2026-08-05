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
  group('PeerProof', () {
    test('signature produced by sign verifies with the signer identity',
        () async {
      final alice = await IdentityKeyPair.generate();
      final alicePub = await _publicKeys(alice);
      final timestamp = DateTime.now().millisecondsSinceEpoch;

      final sig = await PeerProof.sign(
        context: PeerProof.syncHintContext,
        senderOnion: 'alice.onion',
        receiverOnion: 'bob.onion',
        timestampMs: timestamp,
        identity: alice,
      );

      final ok = await PeerProof.verify(
        context: PeerProof.syncHintContext,
        senderOnion: 'alice.onion',
        receiverOnion: 'bob.onion',
        timestampMs: timestamp,
        signature: sig,
        peer: alicePub,
      );
      expect(ok, isTrue);
    });

    test('fails against a different peer public identity', () async {
      final alice = await IdentityKeyPair.generate();
      final mallory = await IdentityKeyPair.generate();
      final malloryPub = await _publicKeys(mallory);
      final timestamp = DateTime.now().millisecondsSinceEpoch;

      final sig = await PeerProof.sign(
        context: PeerProof.syncHintContext,
        senderOnion: 'alice.onion',
        receiverOnion: 'bob.onion',
        timestampMs: timestamp,
        identity: alice,
      );

      final ok = await PeerProof.verify(
        context: PeerProof.syncHintContext,
        senderOnion: 'alice.onion',
        receiverOnion: 'bob.onion',
        timestampMs: timestamp,
        signature: sig,
        peer: malloryPub,
      );
      expect(ok, isFalse);
    });

    test('fails when the sender field is altered', () async {
      final alice = await IdentityKeyPair.generate();
      final alicePub = await _publicKeys(alice);
      final timestamp = DateTime.now().millisecondsSinceEpoch;

      final sig = await PeerProof.sign(
        context: PeerProof.syncHintContext,
        senderOnion: 'alice.onion',
        receiverOnion: 'bob.onion',
        timestampMs: timestamp,
        identity: alice,
      );

      final ok = await PeerProof.verify(
        context: PeerProof.syncHintContext,
        senderOnion: 'attacker.onion',
        receiverOnion: 'bob.onion',
        timestampMs: timestamp,
        signature: sig,
        peer: alicePub,
      );
      expect(ok, isFalse);
    });

    test('fails when the receiver field is altered', () async {
      final alice = await IdentityKeyPair.generate();
      final alicePub = await _publicKeys(alice);
      final timestamp = DateTime.now().millisecondsSinceEpoch;

      final sig = await PeerProof.sign(
        context: PeerProof.syncHintContext,
        senderOnion: 'alice.onion',
        receiverOnion: 'bob.onion',
        timestampMs: timestamp,
        identity: alice,
      );

      final ok = await PeerProof.verify(
        context: PeerProof.syncHintContext,
        senderOnion: 'alice.onion',
        receiverOnion: 'victim.onion',
        timestampMs: timestamp,
        signature: sig,
        peer: alicePub,
      );
      expect(ok, isFalse);
    });

    test('fails when the timestamp field is altered', () async {
      final alice = await IdentityKeyPair.generate();
      final alicePub = await _publicKeys(alice);
      final timestamp = DateTime.now().millisecondsSinceEpoch;

      final sig = await PeerProof.sign(
        context: PeerProof.syncHintContext,
        senderOnion: 'alice.onion',
        receiverOnion: 'bob.onion',
        timestampMs: timestamp,
        identity: alice,
      );

      final ok = await PeerProof.verify(
        context: PeerProof.syncHintContext,
        senderOnion: 'alice.onion',
        receiverOnion: 'bob.onion',
        timestampMs: timestamp + 1,
        signature: sig,
        peer: alicePub,
      );
      expect(ok, isFalse);
    });

    test(
        'sync-hint signature does not verify as a ws-hello (domain separation)',
        () async {
      final alice = await IdentityKeyPair.generate();
      final alicePub = await _publicKeys(alice);
      final timestamp = DateTime.now().millisecondsSinceEpoch;

      final sig = await PeerProof.sign(
        context: PeerProof.syncHintContext,
        senderOnion: 'alice.onion',
        receiverOnion: 'bob.onion',
        timestampMs: timestamp,
        identity: alice,
      );

      final ok = await PeerProof.verify(
        context: PeerProof.wsHelloContext,
        senderOnion: 'alice.onion',
        receiverOnion: 'bob.onion',
        timestampMs: timestamp,
        signature: sig,
        peer: alicePub,
      );
      expect(ok, isFalse);
    });

    test('fails when now is more than maxSkew past the timestamp', () async {
      final alice = await IdentityKeyPair.generate();
      final alicePub = await _publicKeys(alice);
      final now = DateTime.now();
      final timestamp = now
          .subtract(PeerProof.maxSkew + const Duration(minutes: 1))
          .millisecondsSinceEpoch;

      final sig = await PeerProof.sign(
        context: PeerProof.syncHintContext,
        senderOnion: 'alice.onion',
        receiverOnion: 'bob.onion',
        timestampMs: timestamp,
        identity: alice,
      );

      final ok = await PeerProof.verify(
        context: PeerProof.syncHintContext,
        senderOnion: 'alice.onion',
        receiverOnion: 'bob.onion',
        timestampMs: timestamp,
        signature: sig,
        peer: alicePub,
        now: now,
      );
      expect(ok, isFalse);
    });

    test('fails when now is more than maxSkew before the timestamp', () async {
      final alice = await IdentityKeyPair.generate();
      final alicePub = await _publicKeys(alice);
      final now = DateTime.now();
      final timestamp = now
          .add(PeerProof.maxSkew + const Duration(minutes: 1))
          .millisecondsSinceEpoch;

      final sig = await PeerProof.sign(
        context: PeerProof.syncHintContext,
        senderOnion: 'alice.onion',
        receiverOnion: 'bob.onion',
        timestampMs: timestamp,
        identity: alice,
      );

      final ok = await PeerProof.verify(
        context: PeerProof.syncHintContext,
        senderOnion: 'alice.onion',
        receiverOnion: 'bob.onion',
        timestampMs: timestamp,
        signature: sig,
        peer: alicePub,
        now: now,
      );
      expect(ok, isFalse);
    });

    test('malformed base64 returns false rather than throwing', () async {
      final alice = await IdentityKeyPair.generate();
      final alicePub = await _publicKeys(alice);
      final timestamp = DateTime.now().millisecondsSinceEpoch;

      final ok = await PeerProof.verify(
        context: PeerProof.syncHintContext,
        senderOnion: 'alice.onion',
        receiverOnion: 'bob.onion',
        timestampMs: timestamp,
        signature: '!!!not-base64!!!',
        peer: alicePub,
      );
      expect(ok, isFalse);
    });
  });
}
