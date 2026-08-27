import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:prysm/crypto/aead.dart';
import 'package:prysm/crypto/constants.dart';
import 'package:prysm/crypto/identity.dart';
import 'package:prysm/crypto/kdf.dart';
import 'package:prysm/models/unlock_type.dart';
import 'package:prysm/util/logging.dart';

/// Secure storage for identity keys and crypto generation marker.
class CryptoKeyStore {
  CryptoKeyStore._();

  static const String encryptedIdentityKey = 'ENCRYPTED_IDENTITY_V2';
  static const String publicIdentityKey = 'PUBLIC_IDENTITY_V2';
  static const String passphraseSaltKey = 'PASSPHRASE_SALT_V2';
  static const String cryptoGenerationKey = 'CRYPTO_GENERATION';
  static const String torControlPasswordKey = 'TOR_CONTROL_PASSWORD_V1';
  static const String databaseKeyName = 'DATABASE_KEY_V1';

  static const FlutterSecureStorage _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    mOptions: MacOsOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
      synchronizable: false,
      useDataProtectionKeyChain: false,
    ),
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
    } catch (e) {
      Logging.error('SecureStorage read failed for $key: $e', 'CryptoKeyStore');
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
    } catch (e) {
      Logging.error('SecureStorage write failed for $key: $e', 'CryptoKeyStore');
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
    } catch (e) {
      Logging.error('SecureStorage delete failed for $key: $e', 'CryptoKeyStore');
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
    } catch (e) {
      Logging.error('SecureStorage deleteAll failed: $e', 'CryptoKeyStore');
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

  /// Per-installation random Tor control-port password, persisted in secure
  /// storage so every launch authenticates with the same secret.
  ///
  /// The value is base64-url encoded without padding so it is safe to
  /// interpolate into a quoted `AUTHENTICATE "..."` control-protocol line and
  /// to pass as a `--hash-password` argv.
  static Future<String> torControlPassword() async {
    final existing = await read(torControlPasswordKey);
    if (existing != null && existing.isNotEmpty) return existing;
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    final generated = base64Url.encode(bytes).replaceAll('=', '');
    await write(torControlPasswordKey, generated);
    return generated;
  }

  /// Per-installation random 256-bit database key, persisted in secure
  /// storage so every connection opens the encrypted databases with the
  /// same key, even while the app is still locked.
  ///
  /// The value is exactly 64 lowercase hex characters (32 bytes), ready to
  /// interpolate into `PRAGMA key = "x'<hex>'"`: the `x'…'` form makes
  /// SQLCipher use the bytes as the raw key and skip PBKDF2 entirely.
  ///
  /// A stored value that does not match the hex shape is treated as absent
  /// and replaced. This is safe only because no released build has ever
  /// written this key.
  ///
  /// Unlike [torControlPassword], this method fails loudly when the
  /// generated key cannot be durably persisted: [write] swallows
  /// secure-storage failures and falls back to an in-memory map, so after
  /// writing, the fallback map holding the key while the store is not in
  /// test-only mode is treated as a failed write, and the stored key is
  /// additionally verified by reading it back. Silently proceeding with an
  /// ephemeral key would encrypt the user's databases with a key that
  /// disappears at process exit.
  static Future<String> databaseKey() async {
    final existing = await read(databaseKeyName);
    if (existing != null && RegExp(r'^[0-9a-f]{64}$').hasMatch(existing)) {
      return existing;
    }
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    final generated = bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    await write(databaseKeyName, generated);
    // [write] swallows secure-storage failures and falls back to the
    // in-memory map, which would make the readback below match and defeat
    // the fail-loudly guarantee. Outside test-only mode, the fallback map
    // only ever receives this key through that swallowed-failure path, so
    // its presence right after the write means the real write failed.
    if (!_useTestMemoryOnly && _testMemory.containsKey(databaseKeyName)) {
      throw StateError('DATABASE_KEY_V1 could not be persisted to secure storage');
    }
    // Read the key back from the real secure storage, not through [read]:
    // [read] consults the in-memory fallback map whenever it is non-empty,
    // so an unrelated earlier swallowed write (the Tor control password on
    // a flaky keyring, say) would make the readback miss the key that was
    // just durably written and throw a false StateError.
    String? stored;
    if (_useTestMemoryOnly) {
      stored = await read(databaseKeyName);
    } else {
      try {
        stored = await _storage.read(key: databaseKeyName);
      } catch (e) {
        Logging.error(
          'SecureStorage read failed for $databaseKeyName: $e',
          'CryptoKeyStore',
        );
        stored = null;
      }
    }    if (stored == null || stored != generated) {
      throw StateError('DATABASE_KEY_V1 could not be persisted to secure storage');
    }
    return stored;
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
      return await IdentityKeyPair.fromPrivateJson(privateMap);
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
