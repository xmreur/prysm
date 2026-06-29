import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:prysm/crypto/aead.dart';
import 'package:prysm/crypto/constants.dart';
import 'package:prysm/crypto/key_store.dart';
import 'package:prysm/crypto/kdf.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Backup v2: Argon2id + AES-GCM encrypted manifest.
class BackupService {
  BackupService._();

  static const _secureStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  static const _secureKeyNames = [
    CryptoKeyStore.encryptedIdentityKey,
    CryptoKeyStore.publicIdentityKey,
    CryptoKeyStore.passphraseSaltKey,
    CryptoKeyStore.cryptoGenerationKey,
    'PANIC_PIN_HASH',
    'PANIC_PIN_SALT',
  ];

  static Future<void> createBackup(String outputPath, String password) async {
    final docDir = await getApplicationDocumentsDirectory();
    final prysmDir = p.join(docDir.path, 'prysm');

    final dbNames = [
      'chat_app.db',
      'messages.db',
      'pending_messages.db',
      'voice_transcripts.db',
    ];
    final databases = <String, String>{};
    for (final name in dbNames) {
      final file = File(p.join(prysmDir, name));
      if (await file.exists()) {
        databases[name] = base64Encode(await file.readAsBytes());
      }
    }

    final secureKeys = <String, String?>{};
    for (final key in _secureKeyNames) {
      secureKeys[key] = await _secureStorage.read(key: key);
    }

    final prefs = await SharedPreferences.getInstance();
    final prefsData = <String, dynamic>{};
    for (final key in prefs.getKeys()) {
      prefsData[key] = prefs.get(key);
    }

    final manifest = {
      'version': CryptoConstants.backupVersion,
      'timestamp': DateTime.now().toIso8601String(),
      'databases': databases,
      'secureKeys': secureKeys,
      'preferences': prefsData,
    };

    final salt = CryptoKdf.randomBytes(CryptoConstants.saltLength);
    final keyBytes = CryptoKdf.deriveKeyFromPassphrase(password, salt);
    final aeadKey = await CryptoAead.secretKeyFromBytes(keyBytes);
    final enc = await CryptoAead.encryptAesGcm(
      utf8.encode(jsonEncode(manifest)),
      key: aeadKey,
    );
    final output = Uint8List.fromList(salt + enc.nonce + enc.ciphertext);
    await File(outputPath).writeAsBytes(output);
  }

  static Future<bool> restoreBackup(String inputPath, String password) async {
    final file = File(inputPath);
    if (!await file.exists()) return false;

    final data = await file.readAsBytes();
    if (data.length < 16 + 12 + 16) return false;

    final salt = data.sublist(0, 16);
    final nonce = data.sublist(16, 28);
    final ciphertext = data.sublist(28);

    final keyBytes = CryptoKdf.deriveKeyFromPassphrase(password, salt);
    final aeadKey = await CryptoAead.secretKeyFromBytes(keyBytes);

    Uint8List plaintext;
    try {
      plaintext = await CryptoAead.decryptAesGcm(
        ciphertextWithTag: ciphertext,
        key: aeadKey,
        nonce: nonce,
      );
    } catch (_) {
      return false;
    }

    Map<String, dynamic> manifest;
    try {
      manifest = jsonDecode(utf8.decode(plaintext)) as Map<String, dynamic>;
    } catch (_) {
      return false;
    }

    final version = manifest['version'] as int?;
    if (version != CryptoConstants.backupVersion) {
      return false;
    }

    final docDir = await getApplicationDocumentsDirectory();
    final prysmDir = p.join(docDir.path, 'prysm');
    await Directory(prysmDir).create(recursive: true);

    final databases = manifest['databases'] as Map<String, dynamic>? ?? {};
    for (final entry in databases.entries) {
      await File(p.join(prysmDir, entry.key))
          .writeAsBytes(base64Decode(entry.value as String));
    }

    final secureKeys = manifest['secureKeys'] as Map<String, dynamic>? ?? {};
    for (final entry in secureKeys.entries) {
      if (entry.value != null) {
        await _secureStorage.write(
          key: entry.key,
          value: entry.value as String,
        );
      }
    }

    final prefs = await SharedPreferences.getInstance();
    final prefsData = manifest['preferences'] as Map<String, dynamic>? ?? {};
    for (final entry in prefsData.entries) {
      final value = entry.value;
      if (value is bool) {
        await prefs.setBool(entry.key, value);
      } else if (value is int) {
        await prefs.setInt(entry.key, value);
      } else if (value is double) {
        await prefs.setDouble(entry.key, value);
      } else if (value is String) {
        await prefs.setString(entry.key, value);
      } else if (value is List) {
        await prefs.setStringList(entry.key, value.cast<String>());
      }
    }

    return true;
  }
}
