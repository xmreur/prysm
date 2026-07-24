import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/crypto/group_crypto.dart';
import 'package:prysm/crypto/identity.dart';
import 'package:prysm/crypto/ratchet/session_store.dart';
import 'package:prysm/services/group_key_provider.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<Database> _openTestDb() async {
  return databaseFactory.openDatabase(
    inMemoryDatabasePath,
    options: OpenDatabaseOptions(
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE groups (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            avatarBase64 TEXT,
            createdBy TEXT NOT NULL,
            createdAt INTEGER NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE group_keys (
            groupId TEXT PRIMARY KEY,
            encryptedKey TEXT NOT NULL,
            keyVersion INTEGER NOT NULL DEFAULT 1,
            FOREIGN KEY (groupId) REFERENCES groups(id) ON DELETE CASCADE
          )
        ''');
        await RatchetSessionStore.ensureTable(db);
      },
    ),
  );
}

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('GroupKeyProvider', () {
    const groupId = 'g1';

    late Database db;
    late KeyManager keyManager;
    late GroupKeyProvider provider;

    setUp(() async {
      db = await _openTestDb();
      DBHelper.setDatabaseForTest(db);
      keyManager = KeyManager.fromIdentity(await IdentityKeyPair.generate());
      provider = GroupKeyProvider(keyManager: keyManager);
      await db.insert('groups', {
        'id': groupId,
        'name': 'Group One',
        'createdBy': 'me.onion',
        'createdAt': 1000,
      });
    });

    tearDown(() async {
      await db.close();
      DBHelper.setDatabaseForTest(null);
    });

    test('returns null when no key row exists', () async {
      expect(await provider.getDecryptedGroupKey('missing-group'), isNull);
    });

    test('decrypts and returns the stored group key', () async {
      final rawKey = GroupCryptoV2.generateGroupKey();
      final encrypted = await GroupCryptoV2.encryptGroupKeyForStorage(
        rawKey,
        keyManager.identity,
      );
      await DBHelper.upsertGroupKey(
        groupId: groupId,
        encryptedKey: encrypted,
        keyVersion: 1,
      );

      final decrypted = await provider.getDecryptedGroupKey(groupId);

      expect(decrypted, isNotNull);
      expect(decrypted, equals(rawKey));
    });

    test('caches by key version: a same-version DB mutation is not observed', () async {
      final rawKey = GroupCryptoV2.generateGroupKey();
      final encrypted = await GroupCryptoV2.encryptGroupKeyForStorage(
        rawKey,
        keyManager.identity,
      );
      await DBHelper.upsertGroupKey(
        groupId: groupId,
        encryptedKey: encrypted,
        keyVersion: 1,
      );
      final first = await provider.getDecryptedGroupKey(groupId);
      expect(first, equals(rawKey));

      // Corrupt the stored ciphertext without bumping keyVersion: a fresh
      // decrypt would fail, but the cached value should still be served.
      await db.update(
        'group_keys',
        {'encryptedKey': 'not-valid-ciphertext'},
        where: 'groupId = ?',
        whereArgs: [groupId],
      );

      final second = await provider.getDecryptedGroupKey(groupId);
      expect(second, equals(rawKey));
    });

    test('invalidate forces a fresh decrypt at the same key version', () async {
      final rawKey = GroupCryptoV2.generateGroupKey();
      final encrypted = await GroupCryptoV2.encryptGroupKeyForStorage(
        rawKey,
        keyManager.identity,
      );
      await DBHelper.upsertGroupKey(
        groupId: groupId,
        encryptedKey: encrypted,
        keyVersion: 1,
      );
      expect(await provider.getDecryptedGroupKey(groupId), equals(rawKey));

      await db.update(
        'group_keys',
        {'encryptedKey': 'not-valid-ciphertext'},
        where: 'groupId = ?',
        whereArgs: [groupId],
      );
      provider.invalidate(groupId);

      // The corrupted ciphertext fails to decrypt; the provider surfaces
      // that as null rather than throwing.
      expect(await provider.getDecryptedGroupKey(groupId), isNull);
    });

    test('a bumped key version invalidates the cache automatically', () async {
      final firstKey = GroupCryptoV2.generateGroupKey();
      final firstEncrypted = await GroupCryptoV2.encryptGroupKeyForStorage(
        firstKey,
        keyManager.identity,
      );
      await DBHelper.upsertGroupKey(
        groupId: groupId,
        encryptedKey: firstEncrypted,
        keyVersion: 1,
      );
      expect(await provider.getDecryptedGroupKey(groupId), equals(firstKey));

      final rotatedKey = GroupCryptoV2.generateGroupKey();
      final rotatedEncrypted = await GroupCryptoV2.encryptGroupKeyForStorage(
        rotatedKey,
        keyManager.identity,
      );
      await DBHelper.upsertGroupKey(
        groupId: groupId,
        encryptedKey: rotatedEncrypted,
        keyVersion: 2,
      );

      // No explicit invalidate() call: the version bump alone must be enough.
      expect(await provider.getDecryptedGroupKey(groupId), equals(rotatedKey));
    });
  });
}
