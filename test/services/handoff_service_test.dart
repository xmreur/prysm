import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/crypto/identity.dart';
import 'package:prysm/crypto/key_store.dart';
import 'package:prysm/crypto/ratchet/prekey_bundle.dart';
import 'package:prysm/crypto/ratchet/session_store.dart';
import 'package:prysm/services/handoff_service.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    CryptoKeyStore.setUseInMemoryStorageOnly(true);
  });

  tearDown(() async {
    CryptoKeyStore.setUseInMemoryStorageOnly(false);
    DBHelper.setDatabaseForTest(null);
  });

  test('handoff re-init drops sessions and refreshes the OTK pool', () async {
    databaseFactory = databaseFactoryFfi;
    final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
    await RatchetSessionStore.ensureTable(db);
    await db.insert('session_state', {
      'peerId': 'peer.onion',
      'ratchetJson': '{"v":3}',
    });
    DBHelper.setDatabaseForTest(db);

    final identity = await IdentityKeyPair.generate();
    await PrekeyBundle.loadStored(identity);
    final signedBefore =
        await CryptoKeyStore.read(PrekeyBundle.storageSignedPreKeyPrivate);
    expect(signedBefore, isNotNull);
    await CryptoKeyStore.write(
      PrekeyBundle.storageOneTimePreKeyPool,
      '[{"pub":"a","priv":"b"}]',
    );

    await HandoffService.reinitCryptoForHandoff(
      keyManager: KeyManager.fromIdentity(identity),
    );

    final sessions = await db.query('session_state');
    expect(sessions, isEmpty);
    // Signed prekey kept (peers already hold it); pool rebuilt, not the stub.
    expect(
      await CryptoKeyStore.read(PrekeyBundle.storageSignedPreKeyPrivate),
      signedBefore,
    );
    final pool =
        await CryptoKeyStore.read(PrekeyBundle.storageOneTimePreKeyPool);
    expect(pool, isNotNull);
    expect(pool, isNot('[{"pub":"a","priv":"b"}]'));

    await db.close();
  });
}
