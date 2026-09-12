import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'errors.dart';
import 'protocol.dart';

/// `relay-sealed-1`: the metadata-hiding wrapper a sender puts around the
/// *unmodified* Prysm message envelope before depositing it at a relay.
///
/// Ephemeral X25519 -> HKDF-SHA256 (info [RelayProtocol.sealHkdfInfo], salt =
/// ephemeral public key) -> AES-256-GCM. There is deliberately **no outer
/// signature**: authenticity is already carried by the inner envelope, and a
/// signature would give a relay operator an oracle to test candidate public
/// keys against. Authorisation to deposit is knowledge of the mailbox address.
class RelaySeal {
  RelaySeal._();

  static final X25519 _x25519 = X25519();
  static final AesGcm _aes = AesGcm.with256bits();
  static final Random _random = Random.secure();

  static final List<int> _aad = utf8.encode(
      '${RelayProtocol.sealHkdfInfo}|${RelayProtocol.sealScheme}|${RelayProtocol.sealAlg}');

  static Uint8List randomBytes(int length) {
    final out = Uint8List(length);
    for (var i = 0; i < length; i++) {
      out[i] = _random.nextInt(256);
    }
    return out;
  }

  /// True when [envelope] looks like a sealed payload. Cheap shape check only:
  /// [open] is what actually authenticates it.
  static bool isSealed(Map<String, dynamic> envelope) =>
      envelope['scheme'] == RelayProtocol.sealScheme &&
      envelope['crypto'] == RelayProtocol.cryptoVersion &&
      envelope['ephemeralPub'] is String &&
      envelope['nonce'] is String &&
      envelope['ciphertext'] is String;

  /// Seals [plaintext] for the holder of [recipientAgreePublic] (a 32-byte
  /// X25519 public key, the recipient's long-term agreement key).
  static Future<Map<String, dynamic>> seal(
    List<int> plaintext,
    List<int> recipientAgreePublic,
  ) async {
    if (recipientAgreePublic.length != RelayProtocol.x25519KeyBytes) {
      throw RelayError.badRequest('recipient agreement key must be 32 bytes');
    }
    final ephemeral = await _x25519.newKeyPair();
    final ephemeralPublic = await ephemeral.extractPublicKey();
    final shared = await _x25519.sharedSecretKey(
      keyPair: ephemeral,
      remotePublicKey: SimplePublicKey(
        recipientAgreePublic,
        type: KeyPairType.x25519,
      ),
    );
    final key = await _deriveKey(
      await shared.extractBytes(),
      ephemeralPublic.bytes,
    );
    final nonce = randomBytes(RelayProtocol.sealNonceBytes);
    final box = await _aes.encrypt(
      plaintext,
      secretKey: key,
      nonce: nonce,
      aad: _aad,
    );
    return {
      'crypto': RelayProtocol.cryptoVersion,
      'scheme': RelayProtocol.sealScheme,
      'alg': RelayProtocol.sealAlg,
      'ephemeralPub': base64Encode(ephemeralPublic.bytes),
      'nonce': base64Encode(nonce),
      'ciphertext': base64Encode([...box.cipherText, ...box.mac.bytes]),
    };
  }

  /// Opens a sealed payload with the recipient's X25519 agreement key pair.
  ///
  /// Throws [RelayError] with [RelayErrorCode.badRequest] on a malformed
  /// envelope and rethrows the AEAD failure when authentication fails — the
  /// caller must treat both as "drop this item", never as "retry forever".
  static Future<Uint8List> open(
    Map<String, dynamic> envelope,
    KeyPair recipientAgreeKeyPair,
  ) async {
    if (!isSealed(envelope)) {
      throw RelayError.badRequest('not a ${RelayProtocol.sealScheme} envelope');
    }
    final ephemeralBytes = base64Decode(envelope['ephemeralPub'] as String);
    final nonce = base64Decode(envelope['nonce'] as String);
    final ciphertextWithTag = base64Decode(envelope['ciphertext'] as String);
    if (ephemeralBytes.length != RelayProtocol.x25519KeyBytes) {
      throw RelayError.badRequest('ephemeralPub must be 32 bytes');
    }
    if (nonce.length != RelayProtocol.sealNonceBytes) {
      throw RelayError.badRequest('nonce must be 12 bytes');
    }
    if (ciphertextWithTag.length < 16) {
      throw RelayError.badRequest('ciphertext too short');
    }
    final shared = await _x25519.sharedSecretKey(
      keyPair: recipientAgreeKeyPair,
      remotePublicKey: SimplePublicKey(ephemeralBytes, type: KeyPairType.x25519),
    );
    final key = await _deriveKey(await shared.extractBytes(), ephemeralBytes);
    final cut = ciphertextWithTag.length - 16;
    final box = SecretBox(
      ciphertextWithTag.sublist(0, cut),
      nonce: nonce,
      mac: Mac(ciphertextWithTag.sublist(cut)),
    );
    final plain = await _aes.decrypt(box, secretKey: key, aad: _aad);
    return Uint8List.fromList(plain);
  }

  static Future<SecretKey> _deriveKey(
    List<int> sharedSecret,
    List<int> salt,
  ) async {
    final hkdf = Hkdf(
      hmac: Hmac.sha256(),
      outputLength: RelayProtocol.aeadKeyBytes,
    );
    return hkdf.deriveKey(
      secretKey: SecretKey(sharedSecret),
      info: utf8.encode(RelayProtocol.sealHkdfInfo),
      nonce: salt,
    );
  }
}
