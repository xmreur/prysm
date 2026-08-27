import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/crypto/identity.dart';
import 'package:prysm/services/call/group_call_session.dart';
import 'package:prysm/transport/ws_protocol.dart';
import 'package:prysm/util/key_manager.dart';

void main() {
  const members = ['alice.onion', 'bob.onion', 'carol.onion'];

  Future<({GroupCallSession alice, GroupCallSession bob})> makePair() async {
    final aliceId = await IdentityKeyPair.generate();
    final bobId = await IdentityKeyPair.generate();
    final aliceKm = KeyManager.fromIdentity(aliceId);
    final bobKm = KeyManager.fromIdentity(bobId);
    final alicePub = IdentityPublicKeys(
      signPublic: await aliceId.signPublicKey,
      agreePublic: await aliceId.agreePublicKey,
      fingerprint: 'alice',
    );
    final bobPub = IdentityPublicKeys(
      signPublic: await bobId.signPublicKey,
      agreePublic: await bobId.agreePublicKey,
      fingerprint: 'bob',
    );
    final alice = GroupCallSession.createOutbound(
      callId: 'gcall',
      sessionId: 7,
      groupId: 'g1',
      members: members,
      localOnion: 'alice.onion',
    );
    final wrapped = await alice.wrapKeyForPeer(bobPub, aliceKm);
    final bob = await GroupCallSession.fromInbound(
      callId: 'gcall',
      sessionId: 7,
      groupId: 'g1',
      members: members,
      localOnion: 'bob.onion',
      wrappedKey: wrapped,
      keyManager: bobKm,
      peer: alicePub,
    );
    return (alice: alice, bob: bob);
  }

  test('nonce differs per slot at the same seq', () async {
    final pair = await makePair();
    expect(pair.alice.nonceFor(0, 0), isNot(equals(pair.alice.nonceFor(0, 1))));
    expect(pair.alice.nonceFor(0, 0), equals(pair.bob.nonceFor(0, 0)));
  });

  test('wrapped key round-trips audio between two slots', () async {
    final pair = await makePair();
    expect(pair.alice.localSlot, 0);
    expect(pair.bob.localSlot, 1);
    expect(
      await pair.alice.secretKeyBytes(),
      await pair.bob.secretKeyBytes(),
    );

    final frame = await pair.alice.encryptAudioFrame(
      Uint8List.fromList([1, 2, 3]),
    );
    final plain = await pair.bob.decryptAudioFrame(frame, senderSlot: 0);
    expect(plain, [1, 2, 3]);
  });

  test('per-slot replay is rejected and a failed frame does not poison the window',
      () async {
    final pair = await makePair();
    final f0 = await pair.alice.encryptAudioFrame(Uint8List.fromList([1]));
    final f1 = await pair.alice.encryptAudioFrame(Uint8List.fromList([2]));
    expect(await pair.bob.decryptAudioFrame(f0, senderSlot: 0), [1]);
    expect(await pair.bob.decryptAudioFrame(f1, senderSlot: 0), [2]);
    expect(await pair.bob.decryptAudioFrame(f1, senderSlot: 0), isNull);

    final forged = CallAudioFrame(
      sessionId: pair.bob.sessionId,
      seq: 100,
      payload: [0, 1, 2],
    ).encode();
    expect(await pair.bob.decryptAudioFrame(forged, senderSlot: 0), isNull);

    final f2 = await pair.alice.encryptAudioFrame(Uint8List.fromList([3]));
    expect(await pair.bob.decryptAudioFrame(f2, senderSlot: 0), [3]);
  });

  test('decrypting with the wrong slot fails', () async {
    final pair = await makePair();
    final frame = await pair.alice.encryptAudioFrame(
      Uint8List.fromList([9, 9]),
    );
    expect(await pair.bob.decryptAudioFrame(frame, senderSlot: 1), isNull);
    expect(await pair.bob.decryptAudioFrame(frame, senderSlot: 0), [9, 9]);
  });
}
