import 'dart:convert';
import 'dart:core';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'rsa_helper.dart';
import 'package:pointycastle/export.dart';

class KeyManager {
  static const String _encryptedPrivateKeyStorageKey = 'ENCRYPTED_PRIVATE_KEY';
  static const String _publicKeyStorageKey = 'PUBLIC_KEY';
  static const String _pinSaltStorageKey = 'PIN_SALT';
  
  static final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();

  RSAPublicKey? _publicKey;
  RSAPrivateKey? _privateKey;

  bool isCorrupted = false;

  Future<String?> safeRead(String key) async {
    try {
      return await _secureStorage.read(key: key);
    } catch (e) {
      isCorrupted = true;
      return null;
    }
  }

  static Uint8List _randomBytes(int length) {
    final rnd = Random.secure();
    return Uint8List.fromList(List.generate(length, (_) => rnd.nextInt(256)));
  }

  static Uint8List _deriveKey(String pin, Uint8List salt, {int iterations = 100_000, int keyLen = 32}) {
    final pbkdf2 = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64));
    pbkdf2.init(Pbkdf2Parameters(salt, iterations, keyLen));
    return pbkdf2.process(utf8.encode(pin));
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
    String? encPrivate = await safeRead(_encryptedPrivateKeyStorageKey);
    String? privatePem = await safeRead('PRIVATE_KEY'); // Legacy plaintext key
    String? publicPem = await safeRead(_publicKeyStorageKey);
    String? saltB64 = await safeRead(_pinSaltStorageKey);

    if (encPrivate != null && publicPem != null && saltB64 != null) {
      // --- UNLOCK: derive key + decrypt in isolate ---
      final result = await compute(_decryptPrivateKeyIsolate, {
        'pin': pin,
        'encPrivate': encPrivate,
        'saltB64': saltB64,
      });
      if (result == null) return false;
      _privateKey = RSAHelper.privateKeyFromPem(result);
      _publicKey = RSAHelper.publicKeyFromPem(publicPem);
      return true;
    } else if (privatePem != null && publicPem != null) {
      // --- MIGRATION: encrypt legacy plaintext key with PIN (in isolate) ---
      final encMap = await compute(_encryptPrivateKeyIsolate, {
        'pin': pin,
        'privatePem': privatePem,
      });
      final salt = base64Decode(encMap['saltB64']!);
      await _secureStorage.write(
        key: _encryptedPrivateKeyStorageKey, value: encMap['encrypted']!);
      await _secureStorage.write(
        key: _pinSaltStorageKey, value: base64Encode(salt));
      await _secureStorage.delete(key: 'PRIVATE_KEY');
      _privateKey = RSAHelper.privateKeyFromPem(privatePem);
      _publicKey = RSAHelper.publicKeyFromPem(publicPem);
      return true;
    } else if (publicPem != null || encPrivate != null || saltB64 != null) {
      // Partial keystore — never generate new keys over an existing identity.
      isCorrupted = true;
      return false;
    } else {
      // --- FIRST SETUP: generate + encrypt keys in isolate ---
      final result = await compute(_generateAndEncryptKeysIsolate, pin);
      await _secureStorage.write(
        key: _encryptedPrivateKeyStorageKey, value: result['encrypted']!);
      await _secureStorage.write(
        key: _publicKeyStorageKey, value: result['publicPem']!);
      await _secureStorage.write(
        key: _pinSaltStorageKey, value: result['saltB64']!);
      _privateKey = RSAHelper.privateKeyFromPem(result['privatePem']!);
      _publicKey = RSAHelper.publicKeyFromPem(result['publicPem']!);
      return true;
    }
  }

  // ---- Isolate-safe static workers ----

  /// Derives key + decrypts private key. Returns PEM string or null on failure.
  static String? _decryptPrivateKeyIsolate(Map<String, String> params) {
    final pin = params['pin']!;
    final encPrivate = params['encPrivate']!;
    final saltB64 = params['saltB64']!;
    try {
      final salt = base64Decode(saltB64);
      final key = _deriveKey(pin, salt);
      final encMap = jsonDecode(encPrivate) as Map<String, dynamic>;
      final iv = base64Decode(encMap['iv']);
      final ct = base64Decode(encMap['ct']);
      final decrypted = _aesGcmDecrypt(key, iv, ct);
      return utf8.decode(decrypted);
    } catch (_) {
      return null;
    }
  }

  /// Encrypts existing plaintext PEM with PIN. Returns {encrypted, saltB64}.
  static Map<String, String> _encryptPrivateKeyIsolate(Map<String, String> params) {
    final pin = params['pin']!;
    final privatePem = params['privatePem']!;
    final salt = _randomBytes(16);
    final key = _deriveKey(pin, salt);
    final encMap = _aesGcmEncrypt(key, utf8.encode(privatePem));
    return {
      'encrypted': jsonEncode(encMap),
      'saltB64': base64Encode(salt),
    };
  }

  /// Generates RSA key pair + encrypts with PIN. Returns {encrypted, publicPem, privatePem, saltB64}.
  static Map<String, String> _generateAndEncryptKeysIsolate(String pin) {
    final salt = _randomBytes(16);
    final key = _deriveKey(pin, salt);
    final pair = RSAHelper.generateKeyPair();
    final privateKey = pair.privateKey as RSAPrivateKey;
    final publicKey = pair.publicKey as RSAPublicKey;
    final privatePem = RSAHelper.privateKeyToPem(privateKey);
    final publicPem = RSAHelper.publicKeyToPem(publicKey);
    final encMap = _aesGcmEncrypt(key, utf8.encode(privatePem));
    return {
      'encrypted': jsonEncode(encMap),
      'publicPem': publicPem,
      'privatePem': privatePem,
      'saltB64': base64Encode(salt),
    };
  }

  Future<bool> isPinSet() async {
    final encPrivate = await safeRead(_encryptedPrivateKeyStorageKey);
    final salt = await safeRead(_pinSaltStorageKey);
    return encPrivate != null && salt != null;
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

    String get privateKeyPem {
        if (_privateKey == null) throw Exception("Not unlocked");
        return RSAHelper.privateKeyToPem(_privateKey!);
    }

    KeyManager();  // Empty

    factory KeyManager.fromKeys(RSAPrivateKey privateKey, RSAPublicKey publicKey) {
        final km = KeyManager();
        km._privateKey = privateKey;
        km._publicKey = publicKey;
        return km;
    }
}
