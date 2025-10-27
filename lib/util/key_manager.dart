import 'dart:convert';
import 'dart:core';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pointycastle/api.dart';
import 'rsa_helper.dart';
import 'package:pointycastle/asymmetric/api.dart';
import 'package:pointycastle/export.dart';

class KeyManager {
  static const String _encryptedPrivateKeyStorageKey = 'ENCRYPTED_PRIVATE_KEY';
  static const String _publicKeyStorageKey = 'PUBLIC_KEY';
  static const String _pinSaltStorageKey = 'PIN_SALT';
  
  static final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();

  RSAPublicKey? _publicKey;
  RSAPrivateKey? _privateKey;

  static Uint8List _randomBytes(int length) {
    final rnd = Random.secure();
    return Uint8List.fromList(List.generate(length, (_) => rnd.nextInt(256)));
  }

  static Uint8List _deriveKey(String pin, Uint8List salt, {int iterations = 100_000, int keyLen = 32}) {
    final pbkdf2 = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64));
    pbkdf2.init(Pbkdf2Parameters(salt, iterations, keyLen));
    return pbkdf2.process(utf8.encode(pin) as Uint8List);
  }

  static Map<String, String> _aesGcmEncrypt(Uint8List key, Uint8List plain) {
    final gcm = GCMBlockCipher(AESEngine());
    final iv = _randomBytes(12);
    final aeadParams = AEADParameters(KeyParameter(key), 128, iv, Uint8List(0));
    gcm.init(true, aeadParams);

    final cipherText = gcm.process(plain);
    return {
      'iv': base64Encode(iv),
      'ct': base64Encode(cipherText),
    };
  }

  static Uint8List _aesGcmDecrypt(Uint8List key, Uint8List iv, Uint8List ciphertext) {
    final gcm = GCMBlockCipher(AESEngine());
    final aeadParams = AEADParameters(KeyParameter(key), 128, iv, Uint8List(0));
    gcm.init(false, aeadParams);

    return gcm.process(ciphertext);
  }
  
  Future<bool> unlockWithPin(String pin) async {
    String? encPrivate = await _secureStorage.read(key: _encryptedPrivateKeyStorageKey);
    String? privatePem = await _secureStorage.read(key: 'PRIVATE_KEY'); // Legacy plaintext key
    String? publicPem = await _secureStorage.read(key: _publicKeyStorageKey);
    String? saltB64 = await _secureStorage.read(key: _pinSaltStorageKey);

    if (encPrivate != null && publicPem != null && saltB64 != null) {
      // --- UNLOCK: try decrypt with derived key ---
      final salt = base64Decode(saltB64);
      final key = _deriveKey(pin, salt);
      final encMap = jsonDecode(encPrivate) as Map<String, dynamic>;
      final iv = base64Decode(encMap['iv']);
      final ct = base64Decode(encMap['ct']);
      try {
        final decrypted = _aesGcmDecrypt(key, iv, ct);
        final privatePemDecrypted = utf8.decode(decrypted);
        _privateKey = RSAHelper.privateKeyFromPem(privatePemDecrypted);
        _publicKey = RSAHelper.publicKeyFromPem(publicPem);
        return true;
      } catch (_) {
        // Incorrect PIN / decryption failure
        return false;
      }
    } else if (privatePem != null && publicPem != null) {
      // --- MIGRATION: encrypt legacy plaintext key with PIN ---
      final salt = _randomBytes(16);
      final key = _deriveKey(pin, salt);

      final encMap = _aesGcmEncrypt(key, utf8.encode(privatePem) as Uint8List);

      // Store encrypted private key and salt; remove plaintext key
      await _secureStorage.write(
        key: _encryptedPrivateKeyStorageKey, value: jsonEncode(encMap));
      await _secureStorage.write(
        key: _pinSaltStorageKey, value: base64Encode(salt));
      await _secureStorage.delete(key: 'PRIVATE_KEY');

      // Load keys in memory
      _privateKey = RSAHelper.privateKeyFromPem(privatePem);
      _publicKey = RSAHelper.publicKeyFromPem(publicPem);
      return true;
    } else {
      // --- FIRST SETUP: generate, encrypt and store keys ---
      final salt = _randomBytes(16);
      final key = _deriveKey(pin, salt);

      final pair = RSAHelper.generateKeyPair();
      final privateKey = pair.privateKey as RSAPrivateKey;
      final publicKey = pair.publicKey as RSAPublicKey;
      final privatePemNew = RSAHelper.privateKeyToPem(privateKey);
      final publicPemNew = RSAHelper.publicKeyToPem(publicKey);

      final encMap = _aesGcmEncrypt(key, utf8.encode(privatePemNew) as Uint8List);

      await _secureStorage.write(
        key: _encryptedPrivateKeyStorageKey, value: jsonEncode(encMap));
      await _secureStorage.write(
        key: _publicKeyStorageKey, value: publicPemNew);
      await _secureStorage.write(
        key: _pinSaltStorageKey, value: base64Encode(salt));

      _privateKey = privateKey;
      _publicKey = publicKey;
      return true;
    }
  }

  RSAPublicKey get publicKey {
    if (_publicKey == null) throw Exception("Keys not initialized. Call initKeys() first.");
    return _publicKey!;
  }

  RSAPrivateKey get privateKey {
    if (_privateKey == null) throw Exception("Keys not initialized. Call initKeys() first.");
    return _privateKey!;
  }

  String get publicKeyPem => RSAHelper.publicKeyToPem(publicKey);

  /// Encrypt text for peer
  String encryptForPeer(String message, RSAPublicKey peerPublicKey) {
    return RSAHelper.encryptWithPublicKey(message, peerPublicKey);
  }

  /// Encrypt raw bytes for peer
  String encryptBytesForPeer(Uint8List data, RSAPublicKey peerPublicKey) {
    return RSAHelper.encryptBytesWithPublicKey(data, peerPublicKey);
  }

  /// Encrypt text for self
  String encryptForSelf(String message) {
    return RSAHelper.encryptWithPublicKey(message, publicKey);
  }

  /// Encrypt raw bytes for self
  String encryptBytesForSelf(Uint8List data) {
    return RSAHelper.encryptBytesWithPublicKey(data, publicKey);
  }

  /// Decrypt text message
  String decryptMessage(String encrypted) {
    return RSAHelper.decryptWithPrivateKey(encrypted, privateKey);
  }

  /// Decrypt my text message
  String decryptMyMessage(String encryptedMessage) {
    return RSAHelper.decryptWithPrivateKey(encryptedMessage, privateKey);
  }

  /// Decrypt bytes (files/photos)
  Uint8List decryptBytes(String base64Encrypted) {
    final bytes = base64Decode(base64Encrypted);
    return RSAHelper.decryptBytesWithPrivateKey(bytes, privateKey);
  }

  Uint8List decryptMyMessageBytes(String base64Encrypted) {
    return decryptBytes(base64Encrypted);
  }

  RSAPublicKey importPeerPublicKey(String pem) {
    return RSAHelper.publicKeyFromPem(pem);
  }
}
