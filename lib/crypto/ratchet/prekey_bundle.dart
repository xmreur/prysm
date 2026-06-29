import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:prysm/crypto/constants.dart';
import 'package:prysm/crypto/identity.dart';
import 'package:prysm/crypto/key_store.dart';

/// X3DH-style signed prekey bundle published on `/profile`.
class PrekeyBundle {
  PrekeyBundle({
    required this.signedPreKeyPublic,
    required this.signedPreKeySignature,
    required this.oneTimePreKeyPublic,
  });

  final SimplePublicKey signedPreKeyPublic;
  final List<int> signedPreKeySignature;
  final SimplePublicKey oneTimePreKeyPublic;

  static const String storageSignedPreKeyPrivate = 'SIGNED_PREKEY_PRIVATE_V2';
  static const String storageOneTimePreKeyPrivate = 'ONETIME_PREKEY_PRIVATE_V2';

  static final X25519 _x25519 = X25519();

  static Future<PrekeyBundle> generate(
    IdentityKeyPair identity, {
    bool persist = true,
  }) async {
    final signedPreKey = await _x25519.newKeyPair();
    final signedPreKeyPublic = await signedPreKey.extractPublicKey();
    final signedPreKeyPrivate = await signedPreKey.extractPrivateKeyBytes();
    final oneTimePreKey = await _x25519.newKeyPair();
    final oneTimePreKeyPublic = await oneTimePreKey.extractPublicKey();
    final oneTimePreKeyPrivate = await oneTimePreKey.extractPrivateKeyBytes();

    final signPayload = utf8.encode(
      'prysm-prekey:${base64Encode(signedPreKeyPublic.bytes)}',
    );
    final signature = await identity.sign(signPayload);

    if (persist) {
      await CryptoKeyStore.write(
        storageSignedPreKeyPrivate,
        base64Encode(signedPreKeyPrivate),
      );
      await CryptoKeyStore.write(
        storageOneTimePreKeyPrivate,
        base64Encode(oneTimePreKeyPrivate),
      );
    }

    return PrekeyBundle(
      signedPreKeyPublic: signedPreKeyPublic,
      signedPreKeySignature: signature.bytes,
      oneTimePreKeyPublic: oneTimePreKeyPublic,
    );
  }

  static Future<PrekeyBundle?> loadStored(IdentityKeyPair identity) async {
    final signedPrivateB64 =
        await CryptoKeyStore.read(storageSignedPreKeyPrivate);
    final oneTimePrivateB64 =
        await CryptoKeyStore.read(storageOneTimePreKeyPrivate);
    if (signedPrivateB64 == null || oneTimePrivateB64 == null) {
      return generate(identity);
    }

    final signedPrivate = base64Decode(signedPrivateB64);
    final oneTimePrivate = base64Decode(oneTimePrivateB64);
    final signedPreKey = await _x25519.newKeyPairFromSeed(signedPrivate);
    final oneTimePreKey = await _x25519.newKeyPairFromSeed(oneTimePrivate);
    final signedPreKeyPublic = await signedPreKey.extractPublicKey();
    final oneTimePreKeyPublic = await oneTimePreKey.extractPublicKey();
    final signPayload = utf8.encode(
      'prysm-prekey:${base64Encode(signedPreKeyPublic.bytes)}',
    );
    final signature = await identity.sign(signPayload);

    return PrekeyBundle(
      signedPreKeyPublic: signedPreKeyPublic,
      signedPreKeySignature: signature.bytes,
      oneTimePreKeyPublic: oneTimePreKeyPublic,
    );
  }

  Map<String, dynamic> toJson() => {
        'crypto': CryptoConstants.cryptoVersion,
        'signedPreKey': base64Encode(signedPreKeyPublic.bytes),
        'signedPreKeySig': base64Encode(signedPreKeySignature),
        'oneTimePreKey': base64Encode(oneTimePreKeyPublic.bytes),
      };

  static PrekeyBundle fromJson(Map<String, dynamic> json) {
    if (json['crypto'] != CryptoConstants.cryptoVersion) {
      throw FormatException('Unsupported prekey bundle version');
    }
    final signedBytes = base64Decode(json['signedPreKey'] as String);
    final oneTimeBytes = base64Decode(json['oneTimePreKey'] as String);
    return PrekeyBundle(
      signedPreKeyPublic: SimplePublicKey(
        signedBytes,
        type: KeyPairType.x25519,
      ),
      signedPreKeySignature:
          base64Decode(json['signedPreKeySig'] as String),
      oneTimePreKeyPublic: SimplePublicKey(
        oneTimeBytes,
        type: KeyPairType.x25519,
      ),
    );
  }

  Future<bool> verifySignature(IdentityPublicKeys identity) async {
    final signPayload = utf8.encode(
      'prysm-prekey:${base64Encode(signedPreKeyPublic.bytes)}',
    );
    return Ed25519().verify(
      signPayload,
      signature: Signature(
        signedPreKeySignature,
        publicKey: identity.signPublic,
      ),
    );
  }

  /// X3DH-style shared secret for session bootstrap (initiator side).
  static Future<Uint8List> sharedSecretAsInitiator({
    required IdentityKeyPair local,
    required IdentityPublicKeys peer,
    required PrekeyBundle peerBundle,
  }) async {
    final ephemeral = await _x25519.newKeyPair();
    final dh1 = await _x25519.sharedSecretKey(
      keyPair: local.agreeKeyPair,
      remotePublicKey: peerBundle.signedPreKeyPublic,
    );
    final dh2 = await _x25519.sharedSecretKey(
      keyPair: ephemeral,
      remotePublicKey: peer.agreePublic,
    );
    final dh3 = await _x25519.sharedSecretKey(
      keyPair: ephemeral,
      remotePublicKey: peerBundle.signedPreKeyPublic,
    );
    final dh4 = await _x25519.sharedSecretKey(
      keyPair: ephemeral,
      remotePublicKey: peerBundle.oneTimePreKeyPublic,
    );
    final material = Uint8List.fromList([
      ...await dh1.extractBytes(),
      ...await dh2.extractBytes(),
      ...await dh3.extractBytes(),
      ...await dh4.extractBytes(),
    ]);
    return material;
  }

  /// Responder-side shared secret using stored one-time prekey.
  static Future<Uint8List?> sharedSecretAsResponder({
    required IdentityKeyPair local,
    required IdentityPublicKeys peer,
    required SimplePublicKey initiatorEphemeralPublic,
  }) async {
    final signedPrivateB64 =
        await CryptoKeyStore.read(storageSignedPreKeyPrivate);
    final oneTimePrivateB64 =
        await CryptoKeyStore.read(storageOneTimePreKeyPrivate);
    if (signedPrivateB64 == null || oneTimePrivateB64 == null) {
      return null;
    }

    final signedPreKey = await _x25519.newKeyPairFromSeed(
      base64Decode(signedPrivateB64),
    );
    final oneTimePreKey = await _x25519.newKeyPairFromSeed(
      base64Decode(oneTimePrivateB64),
    );

    final dh1 = await _x25519.sharedSecretKey(
      keyPair: signedPreKey,
      remotePublicKey: peer.agreePublic,
    );
    final dh2 = await _x25519.sharedSecretKey(
      keyPair: local.agreeKeyPair,
      remotePublicKey: initiatorEphemeralPublic,
    );
    final dh3 = await _x25519.sharedSecretKey(
      keyPair: signedPreKey,
      remotePublicKey: initiatorEphemeralPublic,
    );
    final dh4 = await _x25519.sharedSecretKey(
      keyPair: oneTimePreKey,
      remotePublicKey: initiatorEphemeralPublic,
    );
    return Uint8List.fromList([
      ...await dh1.extractBytes(),
      ...await dh2.extractBytes(),
      ...await dh3.extractBytes(),
      ...await dh4.extractBytes(),
    ]);
  }
}
