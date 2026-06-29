import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:prysm/crypto/constants.dart';
import 'package:prysm/crypto/kdf.dart';

/// AEAD encrypt/decrypt wrappers (AES-GCM and ChaCha20-Poly1305).
class CryptoAead {
  CryptoAead._();

  static final AesGcm _aesGcm = AesGcm.with256bits();
  static final Cipher _chacha = Chacha20.poly1305Aead();

  static Future<({Uint8List nonce, Uint8List ciphertext})> encryptAesGcm(
    Uint8List plaintext, {
    SecretKey? key,
    Uint8List? nonce,
    List<int> associatedData = const [],
  }) async {
    final secretKey = key ?? await _aesGcm.newSecretKey();
    final iv = nonce ?? CryptoKdf.randomBytes(CryptoConstants.gcmNonceLength);
    final box = await _aesGcm.encrypt(
      plaintext,
      secretKey: secretKey,
      nonce: iv,
      aad: associatedData,
    );
    return (
      nonce: Uint8List.fromList(box.nonce),
      ciphertext: Uint8List.fromList([...box.cipherText, ...box.mac.bytes]),
    );
  }

  static Future<Uint8List> decryptAesGcm({
    required Uint8List ciphertextWithTag,
    required SecretKey key,
    required Uint8List nonce,
    List<int> associatedData = const [],
  }) async {
    if (ciphertextWithTag.length < 16) {
      throw ArgumentError('Ciphertext too short');
    }
    final cipherLen = ciphertextWithTag.length - 16;
    final cipherText = ciphertextWithTag.sublist(0, cipherLen);
    final mac = Mac(ciphertextWithTag.sublist(cipherLen));
    final box = SecretBox(cipherText, nonce: nonce, mac: mac);
    final plain = await _aesGcm.decrypt(
      box,
      secretKey: key,
      aad: associatedData,
    );
    return Uint8List.fromList(plain);
  }

  static Future<SecretKey> secretKeyFromBytes(Uint8List bytes) async {
    return SecretKey(bytes);
  }

  static Future<({Uint8List nonce, Uint8List ciphertext})> encryptChaCha(
    Uint8List plaintext, {
    required SecretKey key,
    Uint8List? nonce,
    List<int> associatedData = const [],
  }) async {
    final iv = nonce ?? CryptoKdf.randomBytes(12);
    final box = await _chacha.encrypt(
      plaintext,
      secretKey: key,
      nonce: iv,
      aad: associatedData,
    );
    return (
      nonce: Uint8List.fromList(box.nonce),
      ciphertext: Uint8List.fromList([...box.cipherText, ...box.mac.bytes]),
    );
  }

  static Future<Uint8List> decryptChaCha({
    required Uint8List ciphertextWithTag,
    required SecretKey key,
    required Uint8List nonce,
    List<int> associatedData = const [],
  }) async {
    if (ciphertextWithTag.length < 16) {
      throw ArgumentError('Ciphertext too short');
    }
    final cipherLen = ciphertextWithTag.length - 16;
    final cipherText = ciphertextWithTag.sublist(0, cipherLen);
    final mac = Mac(ciphertextWithTag.sublist(cipherLen));
    final box = SecretBox(cipherText, nonce: nonce, mac: mac);
    final plain = await _chacha.decrypt(
      box,
      secretKey: key,
      aad: associatedData,
    );
    return Uint8List.fromList(plain);
  }
}
