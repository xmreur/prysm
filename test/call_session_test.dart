import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/crypto/identity.dart';
import 'package:prysm/services/call/call_session.dart';
import 'package:prysm/transport/ws_protocol.dart';
import 'package:prysm/util/key_manager.dart';

void main() {
  test('call audio frame round trip', () async {
    final local = await IdentityKeyPair.generate();
    final peer = await IdentityKeyPair.generate();
    final km = KeyManager.fromIdentity(local);
    final localPub = IdentityPublicKeys(
      signPublic: await local.signPublicKey,
      agreePublic: await local.agreePublicKey,
      fingerprint: 'local',
    );
    final peerPub = IdentityPublicKeys(
      signPublic: await peer.signPublicKey,
      agreePublic: await peer.agreePublicKey,
      fingerprint: 'test',
    );
    final session = CallSession.createOutbound(
      callId: 'c1',
      sessionId: 42,
      peerOnion: 'peer.onion',
    );
    final wrapped = await session.wrapKeyForPeer(peerPub, km);

    final inbound = await CallSession.fromInbound(
      callId: 'c1',
      sessionId: 42,
      peerOnion: 'peer.onion',
      wrappedKey: wrapped,
      keyManager: KeyManager.fromIdentity(peer),
      peer: localPub,
    );

    final frame = await session.encryptAudioFrame(Uint8List.fromList([1, 2, 3]));
    final plain = await inbound.decryptAudioFrame(frame);
    expect(plain, [1, 2, 3]);
  });

  test('rejected frame must not advance the receive window', () async {
    final local = await IdentityKeyPair.generate();
    final peer = await IdentityKeyPair.generate();
    final km = KeyManager.fromIdentity(local);
    final localPub = IdentityPublicKeys(
      signPublic: await local.signPublicKey,
      agreePublic: await local.agreePublicKey,
      fingerprint: 'local',
    );
    final peerPub = IdentityPublicKeys(
      signPublic: await peer.signPublicKey,
      agreePublic: await peer.agreePublicKey,
      fingerprint: 'test',
    );
    final session = CallSession.createOutbound(
      callId: 'c1',
      sessionId: 42,
      peerOnion: 'peer.onion',
    );
    final wrapped = await session.wrapKeyForPeer(peerPub, km);

    final inbound = await CallSession.fromInbound(
      callId: 'c1',
      sessionId: 42,
      peerOnion: 'peer.onion',
      wrappedKey: wrapped,
      keyManager: KeyManager.fromIdentity(peer),
      peer: localPub,
    );

    // Two valid frames (seq 0, 1) are accepted.
    final f0 = await session.encryptAudioFrame(Uint8List.fromList([1, 2, 3]));
    final f1 = await session.encryptAudioFrame(Uint8List.fromList([4, 5, 6]));
    expect(await inbound.decryptAudioFrame(f0), [1, 2, 3]);
    expect(await inbound.decryptAudioFrame(f1), [4, 5, 6]);

    // Forged frame: future seq, payload that fails AEAD verification.
    final forged = CallAudioFrame(
      sessionId: inbound.sessionId,
      seq: 100,
      payload: [0, 1, 2],
    ).encode();
    expect(await inbound.decryptAudioFrame(forged), isNull);

    // A valid frame with seq 2 must still decrypt: the failed frame must not
    // have poisoned the receive window.
    final f2 = await session.encryptAudioFrame(Uint8List.fromList([7, 8, 9]));
    expect(await inbound.decryptAudioFrame(f2), [7, 8, 9]);

    // The forged frame stays rejected, and replays of accepted frames too.
    expect(await inbound.decryptAudioFrame(forged), isNull);
    expect(await inbound.decryptAudioFrame(f1), isNull);
  });
}
