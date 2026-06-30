import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:prysm/crypto/aead.dart';
import 'package:prysm/crypto/constants.dart';
import 'package:prysm/crypto/envelope.dart';
import 'package:prysm/crypto/identity.dart';
import 'package:prysm/crypto/kdf.dart';

/// Wire-format encrypt/decrypt for 1:1 and wrapped payloads.
class CryptoWire {
  CryptoWire._();

  static final X25519 _x25519 = X25519();

  /// Ephemeral X25519 + HKDF + AES-GCM for 1:1 text/binary.
  static Future<String> encryptForPeer(
    Uint8List plaintext,
    IdentityKeyPair sender,
    SimplePublicKey peerAgreePublic,
  ) async {
    final ephemeral = await _x25519.newKeyPair();
    final ephemeralPublic = await ephemeral.extractPublicKey();
    final shared = await _x25519.sharedSecretKey(
      keyPair: ephemeral,
      remotePublicKey: peerAgreePublic,
    );
    final sharedBytes = await shared.extractBytes();
    final aeadKey = await CryptoKdf.hkdf(
      sharedSecret: sharedBytes,
      info: utf8.encode(CryptoConstants.hkdfInfoDhAead),
      salt: ephemeralPublic.bytes,
    );
    final enc = await CryptoAead.encryptAesGcm(plaintext, key: aeadKey);
    final envelope = CryptoEnvelope.dhAead1(
      ephemeralPublic: Uint8List.fromList(ephemeralPublic.bytes),
      ciphertext: enc.ciphertext,
      nonce: enc.nonce,
    );
    return CryptoEnvelope.encode(envelope);
  }

  static Future<String> encryptTextForPeer(
    String plaintext,
    IdentityKeyPair sender,
    SimplePublicKey peerAgreePublic,
  ) =>
      encryptForPeer(utf8.encode(plaintext), sender, peerAgreePublic);

  static Future<Uint8List> decryptFromPeer(
    String wire,
    IdentityKeyPair recipient,
    SimplePublicKey senderAgreePublic,
  ) async {
    final envelope = CryptoEnvelope.tryParse(wire);
    if (envelope == null) {
      throw FormatException('Not a v2 crypto envelope');
    }
    if (CryptoEnvelope.schemeOf(envelope) != CryptoConstants.schemeDhAead1) {
      throw FormatException('Unsupported scheme');
    }
    final ephemeralBytes = base64Decode(envelope['ephemeralPub'] as String);
    final nonce = base64Decode(envelope['nonce'] as String);
    final ciphertext = base64Decode(envelope['ciphertext'] as String);
    final ephemeralPublic = SimplePublicKey(
      ephemeralBytes,
      type: KeyPairType.x25519,
    );
    final shared = await _x25519.sharedSecretKey(
      keyPair: recipient.agreeKeyPair,
      remotePublicKey: ephemeralPublic,
    );
    final sharedBytes = await shared.extractBytes();
    final aeadKey = await CryptoKdf.hkdf(
      sharedSecret: sharedBytes,
      info: utf8.encode(CryptoConstants.hkdfInfoDhAead),
      salt: ephemeralBytes,
    );
    return CryptoAead.decryptAesGcm(
      ciphertextWithTag: ciphertext,
      key: aeadKey,
      nonce: nonce,
    );
  }

  static Future<String> decryptTextFromPeer(
    String wire,
    IdentityKeyPair recipient,
    SimplePublicKey senderAgreePublic,
  ) async {
    final bytes = await decryptFromPeer(wire, recipient, senderAgreePublic);
    return utf8.decode(bytes);
  }

  /// Encrypt for self (uses own agreement public key).
  static Future<String> encryptForSelf(
    Uint8List plaintext,
    IdentityKeyPair identity,
  ) async {
    final pub = await identity.agreePublicKey;
    return encryptForPeer(plaintext, identity, pub);
  }

  static Future<String> encryptTextForSelf(
    String plaintext,
    IdentityKeyPair identity,
  ) =>
      encryptForSelf(utf8.encode(plaintext), identity);

  static Future<Uint8List> decryptForSelf(
    String wire,
    IdentityKeyPair identity,
  ) async {
    final pub = await identity.agreePublicKey;
    return decryptFromPeer(wire, identity, pub);
  }

  static Future<String> decryptTextForSelf(
    String wire,
    IdentityKeyPair identity,
  ) async {
    final bytes = await decryptForSelf(wire, identity);
    return utf8.decode(bytes);
  }

  /// Wrap a symmetric key for a peer (group key distribution, files).
  static Future<Map<String, dynamic>> wrapKeyForPeer(
    Uint8List keyBytes,
    IdentityKeyPair sender,
    SimplePublicKey peerAgreePublic,
  ) async {
    final wire = await encryptForPeer(keyBytes, sender, peerAgreePublic);
    final parsed = CryptoEnvelope.tryParse(wire)!;
    return {
      'ephemeralPub': parsed['ephemeralPub'],
      'nonce': parsed['nonce'],
      'ciphertext': parsed['ciphertext'],
    };
  }

  static Future<Uint8List> unwrapKeyFromPeer(
    Map<String, dynamic> wrapped,
    IdentityKeyPair recipient,
  ) async {
    final wire = CryptoEnvelope.encode({
      'crypto': CryptoConstants.cryptoVersion,
      'scheme': CryptoConstants.schemeDhAead1,
      'alg': 'aes-gcm',
      'ephemeralPub': wrapped['ephemeralPub'],
      'nonce': wrapped['nonce'],
      'ciphertext': wrapped['ciphertext'],
    });
    final pub = await recipient.agreePublicKey;
    return decryptFromPeer(wire, recipient, pub);
  }

  /// File payload: random AEAD key encrypts body; key wrapped for peer/self.
  static Future<({String peerPayload, String selfPayload})> encryptFile(
    Uint8List bytes,
    IdentityKeyPair identity,
    SimplePublicKey peerAgreePublic,
  ) async {
    final fileKey = CryptoKdf.randomBytes(CryptoConstants.aeadKeyLength);
    final aeadKey = await CryptoAead.secretKeyFromBytes(fileKey);
    final enc = await CryptoAead.encryptAesGcm(bytes, key: aeadKey);
    final selfPub = await identity.agreePublicKey;
    final peerWrapped = await wrapKeyForPeer(fileKey, identity, peerAgreePublic);
    final selfWrapped = await wrapKeyForPeer(fileKey, identity, selfPub);
    final peerPayload = CryptoEnvelope.encode(CryptoEnvelope.fileAead1(
      wrappedKey: peerWrapped,
      nonce: enc.nonce,
      ciphertext: enc.ciphertext,
    ));
    final selfPayload = CryptoEnvelope.encode(CryptoEnvelope.fileAead1(
      wrappedKey: selfWrapped,
      nonce: enc.nonce,
      ciphertext: enc.ciphertext,
    ));
    return (peerPayload: peerPayload, selfPayload: selfPayload);
  }

  static Future<Uint8List> decryptFile(
    String wire,
    IdentityKeyPair identity,
  ) async {
    final envelope = CryptoEnvelope.tryParse(wire);
    if (envelope == null || envelope['scheme'] != CryptoConstants.schemeFileAead1) {
      throw FormatException('Invalid file envelope');
    }
    final wrapped = envelope['wrappedKey'] as Map<String, dynamic>;
    final nonce = base64Decode(envelope['nonce'] as String);
    final ciphertext = base64Decode(envelope['ciphertext'] as String);
    final fileKey = await unwrapKeyFromPeer(wrapped, identity);
    final aeadKey = await CryptoAead.secretKeyFromBytes(fileKey);
    return CryptoAead.decryptAesGcm(
      ciphertextWithTag: ciphertext,
      key: aeadKey,
      nonce: nonce,
    );
  }
}
