import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:flutter/foundation.dart';
import 'package:prysm/crypto/aead.dart';
import 'package:prysm/crypto/constants.dart';
import 'package:prysm/crypto/key_store.dart';
import 'package:prysm/crypto/kdf.dart';
import 'package:prysm/crypto/ratchet/prekey_bundle.dart';
import 'package:prysm/database/messages_database.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/util/hs_transfer_keys.dart';
import 'package:prysm/util/logging.dart';
import 'package:prysm/util/pending_message_db_helper.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Backup v3: Argon2id + AES-GCM encrypted manifest.
class BackupService {
  BackupService._();

  @visibleForTesting
  static String? testDocumentsDirectory;

  static const _secureKeyNames = [
    CryptoKeyStore.encryptedIdentityKey,
    CryptoKeyStore.publicIdentityKey,
    CryptoKeyStore.passphraseSaltKey,
    CryptoKeyStore.cryptoGenerationKey,
    CryptoKeyStore.databaseKeyName,
    PrekeyBundle.storageSignedPreKeyPrivate,
    PrekeyBundle.storageOneTimePreKeyPrivate,
    PrekeyBundle.storageOneTimePreKeyPool,
    'PANIC_PIN_HASH',
    'PANIC_PIN_SALT',
  ];

  static Future<void> createBackup(
    String outputPath,
    String password, {
    Map<String, String>? hsKeys,
  }) async {
    final docDir = await _documentsDirectory();
    final prysmDir = p.join(docDir, 'prysm');

    // Checkpoint WALs before reading: WAL mode never rewrites base pages
    // outside a checkpoint, so base files read right after one cannot tear
    // against concurrent writers (only new WAL appends race, and those ship
    // alongside). Best effort: closed or test-only databases simply skip —
    // without this, a live export can copy a torn base file (seen live as a
    // SQLCipher HMAC failure after restore).
    for (final open in [
      DBHelper.database,
      MessagesDatabase.database,
      PendingMessageDbHelper.database,
    ]) {
      try {
        await (await open).execute('PRAGMA wal_checkpoint(TRUNCATE)');
      } catch (e) {
        Logging.warning(
          'WAL checkpoint failed, export may be torn: $e',
          'BackupService',
        );
      }
    }

    // Base files plus their WAL sidecars: a live database keeps recent pages
    // in -wal/-shm, so the base file alone is a stale snapshot — and worse,
    // restoring a base file next to the *target's* leftover sidecars replays
    // foreign pages into it (HMAC failure on SQLCipher). Shipping the
    // source's own sidecars keeps the snapshot fresh; a torn WAL copy is
    // ignored by SQLite, which falls back to the base file.
    const dbNames = [
      'chat_app.db',
      'messages.db',
      'pending_messages.db',
    ];
    const sidecars = ['', '-wal', '-shm'];
    final databases = <String, String>{};
    for (final name in dbNames) {
      for (final suffix in sidecars) {
        final file = File(p.join(prysmDir, '$name$suffix'));
        if (await file.exists()) {
          databases['$name$suffix'] = base64Encode(
            await file.readAsBytes(),
          );
        }
      }
    }

    final secureKeys = <String, String?>{};
    for (final key in _secureKeyNames) {
      secureKeys[key] = await CryptoKeyStore.read(key);
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
      // Null when the source has no hidden-service keys (Tor never started,
      // or a platform whose keys live outside Dart reach and were not
      // supplied): restores like a v2 backup with a fresh onion.
      'hsKeys': hsKeys,
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
    final result = await restoreBackupDetailed(inputPath, password);
    return result.ok;
  }

  /// Restores like [restoreBackup] and reports whether hidden-service keys
  /// were present and installed. Accepts manifests from
  /// [CryptoConstants.backupMinSupportedVersion] through
  /// [CryptoConstants.backupVersion]: a v2 manifest (or a v3 without
  /// `hsKeys`) restores fine but keeps a fresh onion (`hasHsKeys` false).
  static Future<RestoreResult> restoreBackupDetailed(
    String inputPath,
    String password,
  ) async {
    final file = File(inputPath);
    if (!await file.exists()) return RestoreResult.failed;

    final data = await file.readAsBytes();
    if (data.length < 16 + 12 + 16) return RestoreResult.failed;

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
      return RestoreResult.failed;
    }

    Map<String, dynamic> manifest;
    try {
      manifest = jsonDecode(utf8.decode(plaintext)) as Map<String, dynamic>;
    } catch (_) {
      return RestoreResult.failed;
    }

    final version = manifest['version'] as int?;
    if (version == null ||
        version < CryptoConstants.backupMinSupportedVersion ||
        version > CryptoConstants.backupVersion) {
      return RestoreResult.failed;
    }

    final docDir = await _documentsDirectory();
    final prysmDir = p.join(docDir, 'prysm');
    await Directory(prysmDir).create(recursive: true);

    // Keys first, database files second: a crash in between must not leave
    // encrypted database files with no key (every open would then fail
    // until the user restores again). If the keys land first and the files
    // never do, the databases are simply missing and the openers recreate
    // them on next launch.
    final secureKeys = manifest['secureKeys'] as Map<String, dynamic>? ?? {};
    for (final entry in secureKeys.entries) {
      if (entry.value != null) {
        await CryptoKeyStore.write(entry.key, entry.value as String);
      }
    }

    // Drop our own WAL sidecars first: a legacy manifest (or any manifest
    // without sidecars) restored next to live -wal/-shm files would replay
    // foreign pages into the fresh base file and fail its HMAC. Entries the
    // manifest does carry overwrite these paths right after.
    for (final name in [
      'chat_app.db',
      'messages.db',
      'pending_messages.db',
    ]) {
      for (final suffix in ['-wal', '-shm']) {
        final sidecar = File(p.join(prysmDir, '$name$suffix'));
        if (await sidecar.exists()) {
          await sidecar.delete();
        }
      }
    }

    final databases = manifest['databases'] as Map<String, dynamic>? ?? {};
    for (final entry in databases.entries) {
      await File(
        p.join(prysmDir, entry.key),
      ).writeAsBytes(base64Decode(entry.value as String));
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

    // Hidden-service keys last: they decide the onion on next launch, after
    // everything the fresh onion would need is already in place. Desktop
    // installs here (plain files); mobile keys live behind the native
    // channel, so the caller installs them via the payload below.
    final hsKeys = (manifest['hsKeys'] as Map?)?.map(
      (key, value) => MapEntry(key.toString(), value.toString()),
    );
    var hsKeysInstalledOnDesktop = false;
    if (hsKeys != null &&
        hsKeys.isNotEmpty &&
        !Platform.isAndroid &&
        !Platform.isIOS) {
      final docDir = await _documentsDirectory();
      hsKeysInstalledOnDesktop = await HsTransferKeys.installToDirectory(
        HsTransferKeys.hsDirForDocuments(docDir),
        hsKeys,
      );
    }

    return RestoreResult(
      ok: true,
      hasHsKeys: hsKeys != null && hsKeys.isNotEmpty,
      hsKeysInstalledOnDesktop: hsKeysInstalledOnDesktop,
      hsKeys: hsKeys,
    );
  }


  static Future<String> _documentsDirectory() async {
    if (testDocumentsDirectory != null) {
      return testDocumentsDirectory!;
    }
    final docDir = await getApplicationDocumentsDirectory();
    return docDir.path;
  }
}
/// Outcome of [BackupService.restoreBackupDetailed].
class RestoreResult {
  const RestoreResult({
    required this.ok,
    required this.hasHsKeys,
    required this.hsKeysInstalledOnDesktop,
    required this.hsKeys,
  });

  static const failed = RestoreResult(
    ok: false,
    hasHsKeys: false,
    hsKeysInstalledOnDesktop: false,
    hsKeys: null,
  );

  final bool ok;

  /// The manifest carried hidden-service keys (same onion possible).
  final bool hasHsKeys;

  /// Desktop inline install succeeded. Always false on mobile: the caller
  /// installs [hsKeys] through the native channel.
  final bool hsKeysInstalledOnDesktop;

  /// Raw base64 HS files for a caller-side install, null when absent.
  final Map<String, String>? hsKeys;
}
