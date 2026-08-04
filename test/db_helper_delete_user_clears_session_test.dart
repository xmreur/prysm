// Task 9 finding 1 (Low): deleting a contact must also drop the peer's
// Double Ratchet session state from `session_state`, not just the `users`
// row. Pre-fix, DBHelper.deleteUser left the session behind, so the
// cryptographic material of a removed contact survived the removal.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/crypto/ratchet/ratchet_session.dart';
import 'package:prysm/crypto/ratchet/session_store.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<Database> _openDb() async {
  final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
  await db.execute('DROP TABLE IF EXISTS users');
  await db.execute('''
    CREATE TABLE users (
      id TEXT PRIMARY KEY,
      name TEXT,
      avatarUrl TEXT,
      avatarBase64 TEXT,
      customName TEXT,
      publicKeyPem TEXT,
      identityJson TEXT
    )
  ''');
  // DBHelper.setDatabaseForTest wires the ratchet session store onto the
  // injected db (db_helper.dart), so the table must exist for save/load.
  await RatchetSessionStore.ensureTable(db);
  return db;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database db;

  setUp(() async {
    db = await _openDb();
    DBHelper.setDatabaseForTest(db);
  });

  tearDown(() async {
    DBHelper.setDatabaseForTest(null);
    await db.close();
  });

  test('deleteUser also removes the peer ratchet session', () async {
    const peerId = 'peer.onion';
    final shared = Uint8List.fromList(List.generate(32, (i) => i));
    final session = await RatchetSession.initializeAsInitiator(shared);
    final store = RatchetSessionStore(db);
    await store.save(peerId, session);
    expect(await store.load(peerId), isNotNull);

    await db.insert('users', {'id': peerId, 'name': 'Peer'});
    await DBHelper.deleteUser(peerId);

    expect(await store.load(peerId), isNull);
  });
}
