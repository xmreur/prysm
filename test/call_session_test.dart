import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/asymmetric/api.dart';
import 'package:prysm/services/call/call_session.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/rsa_helper.dart';

void main() {
  test('wraps key and encrypts audio round-trip', () {
    final keys = RSAHelper.generateKeyPair(bitLength: 2048);
    final keyManager = KeyManager.fromKeys(
      keys.privateKey as RSAPrivateKey,
      keys.publicKey as RSAPublicKey,
    );
    final caller = CallSession.createOutbound(
      callId: 'call-1',
      sessionId: 99,
      peerOnion: 'peer.onion',
    );
    final wrapped = caller.wrapKeyForPeer(
      keys.publicKey as RSAPublicKey,
      keyManager,
    );
    final callee = CallSession.fromInbound(
      callId: 'call-1',
      sessionId: 99,
      peerOnion: 'peer.onion',
      wrappedKey: wrapped,
      keyManager: keyManager,
    );

    final opus = Uint8List.fromList([1, 2, 3, 4]);
    final wire = caller.encryptAudioFrame(opus);
    final decoded = callee.decryptAudioFrame(wire);

    expect(decoded, opus);
  });

  test('rejects frames with wrong session id', () {
    final keys = RSAHelper.generateKeyPair(bitLength: 2048);
    final keyManager = KeyManager.fromKeys(
      keys.privateKey as RSAPrivateKey,
      keys.publicKey as RSAPublicKey,
    );

    final caller = CallSession.createOutbound(
      callId: 'call-1',
      sessionId: 1,
      peerOnion: 'peer.onion',
    );
    final callee = CallSession.fromInbound(
      callId: 'call-1',
      sessionId: 2,
      peerOnion: 'peer.onion',
      wrappedKey: caller.wrapKeyForPeer(
        keys.publicKey as RSAPublicKey,
        keyManager,
      ),
      keyManager: keyManager,
    );

    final wire = caller.encryptAudioFrame(Uint8List.fromList([9]));
    expect(callee.decryptAudioFrame(wire), isNull);
  });
}
