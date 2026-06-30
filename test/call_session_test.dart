import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/crypto/identity.dart';
import 'package:prysm/services/call/call_session.dart';
import 'package:prysm/util/key_manager.dart';

void main() {
  test('call audio frame round trip', () async {
    final local = await IdentityKeyPair.generate();
    final peer = await IdentityKeyPair.generate();
    final km = KeyManager.fromIdentity(local);
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
    );

    final frame = await session.encryptAudioFrame(Uint8List.fromList([1, 2, 3]));
    final plain = await inbound.decryptAudioFrame(frame);
    expect(plain, [1, 2, 3]);
  });
}
