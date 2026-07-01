import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:prysm/crypto/aead.dart';
import 'package:prysm/crypto/constants.dart';
import 'package:prysm/crypto/identity.dart';
import 'package:prysm/crypto/kdf.dart';
import 'package:prysm/models/unlock_type.dart';

/// Secure storage for identity keys and crypto generation marker.
class CryptoKeyStore {
  CryptoKeyStore._();

  static const String encryptedIdentityKey = 'ENCRYPTED_IDENTITY_V2';
  static const String publicIdentityKey = 'PUBLIC_IDENTITY_V2';
  static const String passphraseSaltKey = 'PASSPHRASE_SALT_V2';
  static const String cryptoGenerationKey = 'CRYPTO_GENERATION';

  static const FlutterSecureStorage _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  static final Map<String, String> _testMemory = {};

  @visibleForTesting
  static void useInMemoryStorageForTest() {
    _testMemory.clear();
  }

  @visibleForTesting
  static void resetInMemoryStorageForTest() {
    _testMemory.clear();
  }

  static Future<String?> read(String key) async {
    if (_testMemory.isNotEmpty || _useTestMemoryOnly) {
      return _testMemory[key];
    }
    try {
      return await _storage.read(key: key);
    } catch (_) {
      return _testMemory[key];
    }
  }

  static bool _useTestMemoryOnly = false;

  @visibleForTesting
  static void setUseInMemoryStorageOnly(bool value) {
    _useTestMemoryOnly = value;
    if (value) {
      _testMemory.clear();
    }
  }

  static Future<void> write(String key, String value) async {
    if (_useTestMemoryOnly) {
      _testMemory[key] = value;
      return;
    }
    try {
      await _storage.write(key: key, value: value);
    } catch (_) {
      _testMemory[key] = value;
    }
  }

  static Future<void> delete(String key) async {
    if (_useTestMemoryOnly) {
      _testMemory.remove(key);
      return;
    }
    try {
      await _storage.delete(key: key);
    } catch (_) {
      _testMemory.remove(key);
    }
  }

  static Future<void> deleteAll() async {
    if (_useTestMemoryOnly) {
      _testMemory.clear();
      return;
    }
    try {
      await _storage.deleteAll();
    } catch (_) {
      _testMemory.clear();
    }
  }

  static bool isValidUnlockSecret(String secret, UnlockType type) {
    switch (type) {
      case UnlockType.pin:
        return RegExp(r'^\d{6}$').hasMatch(secret);
      case UnlockType.passphrase:
        return secret.length >= CryptoConstants.minPassphraseLength;
    }
  }

  /// @deprecated Use [isValidUnlockSecret] with [UnlockType.passphrase].
  static bool isValidPassphrase(String passphrase) {
    return isValidUnlockSecret(passphrase, UnlockType.passphrase);
  }

  static Future<bool> isPassphraseSet() async {
    final enc = await read(encryptedIdentityKey);
    final salt = await read(passphraseSaltKey);
    return enc != null && salt != null;
  }

  static Future<int?> cryptoGeneration() async {
    final raw = await read(cryptoGenerationKey);
    return raw == null ? null : int.tryParse(raw);
  }

  static Future<void> setCryptoGeneration(int generation) async {
    await write(cryptoGenerationKey, '$generation');
  }

  /// Detect legacy RSA-era storage.
  static Future<bool> hasLegacyRsaStorage() async {
    final legacy = await read('ENCRYPTED_PRIVATE_KEY');
    final legacyPub = await read('PUBLIC_KEY');
    final legacyPlain = await read('PRIVATE_KEY');
    return legacy != null || legacyPub != null || legacyPlain != null;
  }

  static Future<bool> needsCryptoMigration() async {
    if (await hasLegacyRsaStorage()) return true;
    final gen = await cryptoGeneration();
    if (gen != null && gen >= CryptoConstants.cryptoGeneration) {
      return false;
    }
    if (await isPassphraseSet()) {
      await setCryptoGeneration(CryptoConstants.cryptoGeneration);
      return false;
    }
    return false;
  }

  static Future<Map<String, String>> encryptIdentity({
    required String passphrase,
    required IdentityKeyPair identity,
  }) async {
    final privateJson = jsonEncode(await identity.toPrivateJson());
    final publicJson = jsonEncode(await identity.toPublicJson());
    final salt = CryptoKdf.randomBytes(CryptoConstants.saltLength);
    final keyBytes = CryptoKdf.deriveKeyFromPassphrase(passphrase, salt);
    final aeadKey = await CryptoAead.secretKeyFromBytes(keyBytes);
    final enc = await CryptoAead.encryptAesGcm(utf8.encode(privateJson), key: aeadKey);
    return {
      'encrypted': jsonEncode({
        'keystore': CryptoConstants.keystoreVersion,
        'iv': base64Encode(enc.nonce),
        'ct': base64Encode(enc.ciphertext),
      }),
      'saltB64': base64Encode(salt),
      'publicJson': publicJson,
    };
  }

  static Future<IdentityKeyPair?> decryptIdentity({
    required String passphrase,
    required String encrypted,
    required String saltB64,
  }) async {
    try {
      final salt = base64Decode(saltB64);
      final keyBytes = CryptoKdf.deriveKeyFromPassphrase(passphrase, salt);
      final aeadKey = await CryptoAead.secretKeyFromBytes(keyBytes);
      final encMap = jsonDecode(encrypted) as Map<String, dynamic>;
      final iv = base64Decode(encMap['iv'] as String);
      final ct = base64Decode(encMap['ct'] as String);
      final plain = await CryptoAead.decryptAesGcm(
        ciphertextWithTag: ct,
        key: aeadKey,
        nonce: iv,
      );
      final privateMap = jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;
      return IdentityKeyPair.fromPrivateJson(privateMap);
    } catch (_) {
      return null;
    }
  }

  static Future<void> persistIdentity({
    required String passphrase,
    required IdentityKeyPair identity,
  }) async {
    final enc = await encryptIdentity(passphrase: passphrase, identity: identity);
    await write(encryptedIdentityKey, enc['encrypted']!);
    await write(publicIdentityKey, enc['publicJson']!);
    await write(passphraseSaltKey, enc['saltB64']!);
    await setCryptoGeneration(CryptoConstants.cryptoGeneration);
  }

  @visibleForTesting
  static Future<Map<String, String>> testEncryptIdentity({
    required String passphrase,
    required IdentityKeyPair identity,
  }) =>
      encryptIdentity(passphrase: passphrase, identity: identity);

  @visibleForTesting
  static Future<IdentityKeyPair?> testDecryptIdentity({
    required String passphrase,
    required String encrypted,
    required String saltB64,
  }) =>
      decryptIdentity(
        passphrase: passphrase,
        encrypted: encrypted,
        saltB64: saltB64,
      );
}
