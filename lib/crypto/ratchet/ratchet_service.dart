import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:prysm/crypto/constants.dart';
import 'package:prysm/crypto/identity.dart';
import 'package:prysm/crypto/ratchet/prekey_bundle.dart';
import 'package:prysm/crypto/ratchet/ratchet_session.dart';
import 'package:prysm/crypto/ratchet/session_store.dart';
import 'package:prysm/crypto/wire.dart';

/// High-level 1:1 ratchet encrypt/decrypt with SQLite session persistence.
class RatchetService {
  RatchetService._();
  static final RatchetService instance = RatchetService._();

  static final X25519 _x25519 = X25519();

  Future<String> encryptText({
    required String peerId,
    required String plaintext,
    required IdentityKeyPair local,
    required IdentityPublicKeys peer,
    PrekeyBundle? peerBundle,
  }) async {
    final wire = await encryptBytes(
      peerId: peerId,
      plaintext: utf8.encode(plaintext),
      local: local,
      peer: peer,
      peerBundle: peerBundle,
    );
    return wire;
  }

  Future<String> encryptBytes({
    required String peerId,
    required Uint8List plaintext,
    required IdentityKeyPair local,
    required IdentityPublicKeys peer,
    PrekeyBundle? peerBundle,
  }) async {
    var session = await RatchetSessionStore.load(peerId);
    Map<String, dynamic> handshake = {};

    if (session == null) {
      final bundle = peerBundle;
      if (bundle == null) {
        throw StateError('Missing prekey bundle for $peerId');
      }
      final ephemeral = await _x25519.newKeyPair();
      final ephemeralPublic = await ephemeral.extractPublicKey();
      final shared = await PrekeyBundle.sharedSecretAsInitiator(
        local: local,
        peer: peer,
        peerBundle: bundle,
      );
      session = await RatchetSession.initializeAsInitiator(shared);
      handshake = {
        'ephemeralPub': base64Encode(ephemeralPublic.bytes),
      };
    }

    final result = await session.encryptMessage(plaintext);
    await RatchetSessionStore.save(peerId, session);
    if (handshake.isEmpty) {
      return result.wire;
    }
    final envelope = jsonDecode(result.wire) as Map<String, dynamic>;
    envelope['handshake'] = handshake;
    return jsonEncode(envelope);
  }

  Future<String> decryptText({
    required String peerId,
    required String wire,
    required IdentityKeyPair local,
    required IdentityPublicKeys peer,
  }) =>
      decryptBytes(
        peerId: peerId,
        wire: wire,
        local: local,
        peer: peer,
      ).then(utf8.decode);

  Future<Uint8List> decryptBytes({
    required String peerId,
    required String wire,
    required IdentityKeyPair local,
    required IdentityPublicKeys peer,
  }) async {
    final envelope = jsonDecode(wire) as Map<String, dynamic>;
    final scheme = envelope['scheme'] as String?;

    if (scheme == CryptoConstants.schemeDhAead1) {
      return CryptoWire.decryptFromPeer(wire, local, peer.agreePublic);
    }

    if (scheme != CryptoConstants.schemeRatchet1) {
      if (envelope['crypto'] == CryptoConstants.cryptoVersion) {
        return CryptoWire.decryptFromPeer(wire, local, peer.agreePublic);
      }
      throw FormatException('Unsupported ciphertext scheme: $scheme');
    }

    try {
      var session = await RatchetSessionStore.load(peerId);
      if (session == null) {
        final handshake = envelope['handshake'] as Map<String, dynamic>?;
        if (handshake == null) {
          throw StateError('Missing ratchet handshake for $peerId');
        }
        final ephemeralBytes =
            base64Decode(handshake['ephemeralPub'] as String);
        final ephemeralPublic = SimplePublicKey(
          ephemeralBytes,
          type: KeyPairType.x25519,
        );
        final shared = await PrekeyBundle.sharedSecretAsResponder(
          local: local,
          peer: peer,
          initiatorEphemeralPublic: ephemeralPublic,
        );
        if (shared == null) {
          throw StateError('Cannot derive ratchet session for $peerId');
        }
        session = await RatchetSession.initializeAsResponder(shared);
      }

      final plain = await session.decryptMessage(wire);
      await RatchetSessionStore.save(peerId, session);
      return plain;
    } catch (e) {
      return CryptoWire.decryptFromPeer(wire, local, peer.agreePublic);
    }
  }
}
