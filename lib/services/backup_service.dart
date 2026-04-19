import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pointycastle/digests/sha256.dart';
import 'package:pointycastle/key_derivators/pbkdf2.dart';
import 'package:pointycastle/key_derivators/api.dart';
import 'package:pointycastle/macs/hmac.dart';
import 'package:pointycastle/api.dart';
import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/block/modes/gcm.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Handles backup and restore of all app data:
/// - 3 SQLite databases (chat_app.db, messages.db, pending_messages.db)
/// - FlutterSecureStorage keys (ENCRYPTED_PRIVATE_KEY, PUBLIC_KEY, PIN_SALT)
/// - SharedPreferences settings
///
/// Backup format: AES-256-GCM encrypted JSON containing base64-encoded DB files
/// and key/settings data, wrapped with a PBKDF2-derived key from a user password.
class BackupService {
  static const _secureStorage = FlutterSecureStorage();
  static const _backupVersion = 1;

  static Uint8List _randomBytes(int length) {
    final rnd = Random.secure();
    return Uint8List.fromList(List.generate(length, (_) => rnd.nextInt(256)));
  }

  static Uint8List _deriveKey(String password, Uint8List salt) {
    final pbkdf2 = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64));
    pbkdf2.init(Pbkdf2Parameters(salt, 100000, 32));
    return pbkdf2.process(utf8.encode(password));
  }

  static Uint8List _encrypt(Uint8List key, Uint8List plaintext) {
    final gcm = GCMBlockCipher(AESEngine());
    final iv = _randomBytes(12);
    gcm.init(true, AEADParameters(KeyParameter(key), 128, iv, Uint8List(0)));
    final ciphertext = gcm.process(plaintext);
    // Prepend IV (12 bytes) to ciphertext
    return Uint8List.fromList(iv + ciphertext);
  }

  static Uint8List _decrypt(Uint8List key, Uint8List data) {
    final iv = data.sublist(0, 12);
    final ciphertext = data.sublist(12);
    final gcm = GCMBlockCipher(AESEngine());
    gcm.init(false, AEADParameters(KeyParameter(key), 128, iv, Uint8List(0)));
    return gcm.process(ciphertext);
  }

  /// Create a backup file at [outputPath], encrypted with [password].
  static Future<void> createBackup(String outputPath, String password) async {
    final docDir = await getApplicationDocumentsDirectory();
    final prysmDir = p.join(docDir.path, 'prysm');

    // Collect database files
    final dbNames = ['chat_app.db', 'messages.db', 'pending_messages.db'];
    final databases = <String, String>{};
    for (final name in dbNames) {
      final file = File(p.join(prysmDir, name));
      if (await file.exists()) {
        databases[name] = base64Encode(await file.readAsBytes());
      }
    }

    // Collect secure storage keys
    final secureKeys = <String, String?>{};
    for (final key in ['ENCRYPTED_PRIVATE_KEY', 'PUBLIC_KEY', 'PIN_SALT']) {
      secureKeys[key] = await _secureStorage.read(key: key);
    }

    // Collect SharedPreferences
    final prefs = await SharedPreferences.getInstance();
    final prefsData = <String, dynamic>{};
    for (final key in prefs.getKeys()) {
      prefsData[key] = prefs.get(key);
    }

    // Build manifest
    final manifest = {
      'version': _backupVersion,
      'timestamp': DateTime.now().toIso8601String(),
      'databases': databases,
      'secureKeys': secureKeys,
      'preferences': prefsData,
    };

    final plaintext = utf8.encode(jsonEncode(manifest));

    // Encrypt
    final salt = _randomBytes(16);
    final key = _deriveKey(password, salt);
    final encrypted = _encrypt(key, Uint8List.fromList(plaintext));

    // Write: [salt (16 bytes)][encrypted data]
    final output = File(outputPath);
    await output.writeAsBytes(salt + encrypted);
  }

  /// Restore from a backup file at [inputPath], decrypted with [password].
  /// Returns true on success, false on wrong password / corrupt file.
  static Future<bool> restoreBackup(String inputPath, String password) async {
    final file = File(inputPath);
    if (!await file.exists()) return false;

    final data = await file.readAsBytes();
    if (data.length < 28) return false; // salt(16) + iv(12) + min data

    final salt = data.sublist(0, 16);
    final encrypted = Uint8List.fromList(data.sublist(16));

    final key = _deriveKey(password, Uint8List.fromList(salt));

    Uint8List plaintext;
    try {
      plaintext = _decrypt(key, encrypted);
    } catch (_) {
      return false; // Wrong password or corrupt
    }

    Map<String, dynamic> manifest;
    try {
      manifest = jsonDecode(utf8.decode(plaintext)) as Map<String, dynamic>;
    } catch (_) {
      return false;
    }

    final docDir = await getApplicationDocumentsDirectory();
    final prysmDir = p.join(docDir.path, 'prysm');
    await Directory(prysmDir).create(recursive: true);

    // Restore databases
    final databases = manifest['databases'] as Map<String, dynamic>? ?? {};
    for (final entry in databases.entries) {
      final bytes = base64Decode(entry.value as String);
      await File(p.join(prysmDir, entry.key)).writeAsBytes(bytes);
    }

    // Restore secure storage keys
    final secureKeys = manifest['secureKeys'] as Map<String, dynamic>? ?? {};
    for (final entry in secureKeys.entries) {
      if (entry.value != null) {
        await _secureStorage.write(key: entry.key, value: entry.value as String);
      }
    }

    // Restore SharedPreferences
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
        await prefs.setStringList(
            entry.key, value.cast<String>());
      }
    }

    return true;
  }
}
