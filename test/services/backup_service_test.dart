import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/crypto/aead.dart';
import 'package:prysm/crypto/constants.dart';
import 'package:prysm/crypto/kdf.dart';
import 'package:prysm/crypto/key_store.dart';
import 'package:prysm/crypto/ratchet/prekey_bundle.dart';
import 'package:prysm/services/backup_service.dart';
import 'package:prysm/util/hs_transfer_keys.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Writes a raw manifest envelope like [BackupService.createBackup] does,
/// so tests can craft legacy/future versions the current writer never emits.
Future<void> _writeRawManifest(
  String path,
  String password,
  Map<String, dynamic> manifest,
) async {
  final salt = CryptoKdf.randomBytes(CryptoConstants.saltLength);
  final keyBytes = CryptoKdf.deriveKeyFromPassphrase(password, salt);
  final aeadKey = await CryptoAead.secretKeyFromBytes(keyBytes);
  final enc = await CryptoAead.encryptAesGcm(
    utf8.encode(jsonEncode(manifest)),
    key: aeadKey,
  );
  await File(
    path,
  ).writeAsBytes(Uint8List.fromList(salt + enc.nonce + enc.ciphertext));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    CryptoKeyStore.setUseInMemoryStorageOnly(true);
    BackupService.testDocumentsDirectory = Directory.systemTemp.path;
  });

  tearDown(() {
    CryptoKeyStore.setUseInMemoryStorageOnly(false);
    BackupService.testDocumentsDirectory = null;
  });

  test('backup round trip restores prekey secure storage keys', () async {
    const signedValue = 'signed-prekey-test';
    const poolValue = '["otpk1","otpk2"]';

    await CryptoKeyStore.write(
      PrekeyBundle.storageSignedPreKeyPrivate,
      signedValue,
    );
    await CryptoKeyStore.write(
      PrekeyBundle.storageOneTimePreKeyPool,
      poolValue,
    );

    final backupPath =
        '${Directory.systemTemp.path}/prysm_backup_test_${DateTime.now().microsecondsSinceEpoch}.bin';
    await BackupService.createBackup(backupPath, 'backup-test-passphrase');

    await CryptoKeyStore.delete(PrekeyBundle.storageSignedPreKeyPrivate);
    await CryptoKeyStore.delete(PrekeyBundle.storageOneTimePreKeyPool);

    expect(
      await CryptoKeyStore.read(PrekeyBundle.storageSignedPreKeyPrivate),
      isNull,
    );
    expect(
      await CryptoKeyStore.read(PrekeyBundle.storageOneTimePreKeyPool),
      isNull,
    );

    final restored = await BackupService.restoreBackup(
      backupPath,
      'backup-test-passphrase',
    );
    expect(restored, isTrue);
    expect(
      await CryptoKeyStore.read(PrekeyBundle.storageSignedPreKeyPrivate),
      signedValue,
    );
    expect(
      await CryptoKeyStore.read(PrekeyBundle.storageOneTimePreKeyPool),
      poolValue,
    );

    await File(backupPath).delete();
  });

  test('backup round trip restores the database key', () async {
    const dbKey =
        '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

    await CryptoKeyStore.write(CryptoKeyStore.databaseKeyName, dbKey);

    final backupPath =
        '${Directory.systemTemp.path}/prysm_backup_dbkey_${DateTime.now().microsecondsSinceEpoch}.bin';
    await BackupService.createBackup(backupPath, 'backup-test-passphrase');

    await CryptoKeyStore.delete(CryptoKeyStore.databaseKeyName);
    expect(await CryptoKeyStore.read(CryptoKeyStore.databaseKeyName), isNull);

    final restored = await BackupService.restoreBackup(
      backupPath,
      'backup-test-passphrase',
    );
    expect(restored, isTrue);
    expect(await CryptoKeyStore.read(CryptoKeyStore.databaseKeyName), dbKey);

    await File(backupPath).delete();
  });

  test('v3 round trip carries hsKeys and installs them on desktop', () async {
    final hsDir =
        '${Directory.systemTemp.path}/prysm_hs_src_${DateTime.now().microsecondsSinceEpoch}';
    await Directory(hsDir).create(recursive: true);
    await File('$hsDir/hostname').writeAsString('${'z' * 56}.onion');
    await File('$hsDir/hs_ed25519_secret_key').writeAsBytes(List.filled(96, 7));
    await File('$hsDir/hs_ed25519_public_key').writeAsBytes(List.filled(32, 9));

    final hsKeys = await HsTransferKeys.collectFromDirectory(hsDir);
    expect(hsKeys, isNotNull);

    final backupPath =
        '${Directory.systemTemp.path}/prysm_backup_v3_${DateTime.now().microsecondsSinceEpoch}.bin';
    await BackupService.createBackup(
      backupPath,
      'backup-test-passphrase',
      hsKeys: hsKeys,
    );

    final result = await BackupService.restoreBackupDetailed(
      backupPath,
      'backup-test-passphrase',
    );
    expect(result.ok, isTrue);
    expect(result.hasHsKeys, isTrue);
    expect(result.hsKeysInstalledOnDesktop, isTrue);
    // Desktop inline install landed in the test documents dir.
    final installedHostname = File(
      '${Directory.systemTemp.path}/prysm/tor_executable/tor_data/hidden_service/hostname',
    );
    expect(await installedHostname.readAsString(), '${'z' * 56}.onion');

    await Directory(hsDir).delete(recursive: true);
    await File(backupPath).delete();
    await Directory(
      '${Directory.systemTemp.path}/prysm',
    ).delete(recursive: true);
  });

  test('legacy v2 manifest restores without hsKeys', () async {
    // A live target leaves -wal/-shm next to our DBs: restoring a manifest
    // without sidecars must drop them, or foreign pages replay into the
    // fresh base file (SQLCipher HMAC failure, seen live).
    final staleWal = File('${Directory.systemTemp.path}/prysm/messages.db-wal');
    await staleWal.parent.create(recursive: true);
    await staleWal.writeAsString('foreign wal pages');
    final backupPath =
        '${Directory.systemTemp.path}/prysm_backup_v2_${DateTime.now().microsecondsSinceEpoch}.bin';
    await _writeRawManifest(backupPath, 'backup-test-passphrase', {
      'version': 2,
      'timestamp': DateTime.now().toIso8601String(),
      'databases': <String, String>{},
      'secureKeys': <String, String?>{},
      'preferences': <String, dynamic>{},
    });

    final result = await BackupService.restoreBackupDetailed(
      backupPath,
      'backup-test-passphrase',
    );
    expect(result.ok, isTrue);
    expect(result.hasHsKeys, isFalse);
    expect(result.hsKeysInstalledOnDesktop, isFalse);
    expect(await BackupService.restoreBackup(backupPath, 'wrong'), isFalse);

    expect(await staleWal.exists(), isFalse);
    await File(backupPath).delete();
  });

  test('unsupported versions are rejected', () async {
    for (final version in [1, 99]) {
      final backupPath =
          '${Directory.systemTemp.path}/prysm_backup_v${version}_${DateTime.now().microsecondsSinceEpoch}.bin';
      await _writeRawManifest(backupPath, 'backup-test-passphrase', {
        'version': version,
        'timestamp': DateTime.now().toIso8601String(),
        'databases': <String, String>{},
        'secureKeys': <String, String?>{},
        'preferences': <String, dynamic>{},
      });
      final result = await BackupService.restoreBackupDetailed(
        backupPath,
        'backup-test-passphrase',
      );
      expect(result.ok, isFalse, reason: 'version $version');
      await File(backupPath).delete();
    }
  });

  test('hsKeys collect returns null when files are missing', () async {
    expect(
      await HsTransferKeys.collectFromDirectory(
        '${Directory.systemTemp.path}/prysm_hs_absent_${DateTime.now().microsecondsSinceEpoch}',
      ),
      isNull,
    );
    expect(
      await HsTransferKeys.installToDirectory(
        '${Directory.systemTemp.path}/prysm_hs_bad',
        {'hostname': 'bm90LWFuLW9uaW9u'},
      ),
      isFalse,
    );
  });

  test(
    'installToDirectory rejects invalid keys without partial writes',
    () async {
      final dir =
          '${Directory.systemTemp.path}/prysm_hs_reject_${DateTime.now().microsecondsSinceEpoch}';
      String b64(List<int> bytes) => base64Encode(bytes);

      // Seed valid keys first: bad input must not clobber or half-replace them.
      final good = {
        'hostname': b64(utf8.encode('${'z' * 56}.onion')),
        'hs_ed25519_secret_key': b64(List.filled(96, 7)),
        'hs_ed25519_public_key': b64(List.filled(32, 9)),
      };
      expect(await HsTransferKeys.installToDirectory(dir, good), isTrue);
      final before = <String, List<int>>{
        for (final name in [
          'hostname',
          'hs_ed25519_secret_key',
          'hs_ed25519_public_key',
        ])
          name: await File('$dir/$name').readAsBytes(),
      };

      final badCases = [
        // Not base64 at all.
        {
          'hostname': '!!!',
          'hs_ed25519_secret_key': '!!!',
          'hs_ed25519_public_key': '!!!',
        },
        // Missing fields.
        {'hostname': b64(utf8.encode('x.onion'))},
        // Empty strings.
        {
          'hostname': '',
          'hs_ed25519_secret_key': '',
          'hs_ed25519_public_key': '',
        },
        // Valid base64, empty after decode.
        {
          'hostname': b64(utf8.encode('   ')),
          'hs_ed25519_secret_key': b64([]),
          'hs_ed25519_public_key': b64([]),
        },
      ];
      for (final bad in badCases) {
        expect(await HsTransferKeys.installToDirectory(dir, bad), isFalse);
      }

      // Originals untouched, no .tmp leftovers.
      for (final entry in before.entries) {
        expect(await File('$dir/${entry.key}').readAsBytes(), entry.value);
      }
      expect(
        Directory(dir).listSync().where((e) => e.path.endsWith('.tmp')).isEmpty,
        isTrue,
      );

      await Directory(dir).delete(recursive: true);
    },
  );

  test('deleteDirectory removes the dir and is true when absent', () async {
    final stamp = DateTime.now().microsecondsSinceEpoch;
    expect(
      await HsTransferKeys.deleteDirectory(
        '${Directory.systemTemp.path}/prysm_hs_gone_$stamp',
      ),
      isTrue,
    );
    final dir = '${Directory.systemTemp.path}/prysm_hs_del_$stamp';
    String b64(List<int> bytes) => base64Encode(bytes);
    final keys = {
      'hostname': b64(utf8.encode("${'z' * 56}.onion")),
      'hs_ed25519_secret_key': b64(List.filled(96, 7)),
      'hs_ed25519_public_key': b64(List.filled(32, 9)),
    };
    expect(await HsTransferKeys.installToDirectory(dir, keys), isTrue);
    for (final name in [
      'hostname',
      'hs_ed25519_secret_key',
      'hs_ed25519_public_key',
    ]) {
      final file = File('$dir/$name');
      expect(await file.exists(), isTrue, reason: '$name installed');
      expect(await file.length() > 0, isTrue, reason: '$name non-empty');
    }
    expect(await HsTransferKeys.deleteDirectory(dir), isTrue);
    expect(await Directory(dir).exists(), isFalse);
  });
}
