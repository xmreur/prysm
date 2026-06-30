import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/crypto/key_store.dart';
import 'package:prysm/crypto/ratchet/prekey_bundle.dart';
import 'package:prysm/services/backup_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

    final restored =
        await BackupService.restoreBackup(backupPath, 'backup-test-passphrase');
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
}
