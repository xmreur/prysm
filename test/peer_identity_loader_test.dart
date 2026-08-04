import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/crypto/identity.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/peer_identity_loader.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<Database> _openUsersDb() async {
  final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
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
  return db;
}

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database db;
  late KeyManager keyManager;

  setUp(() async {
    db = await _openUsersDb();
    DBHelper.setDatabaseForTest(db);
    keyManager = KeyManager.fromIdentity(await IdentityKeyPair.generate());
  });

  tearDown(() async {
    await db.close();
    DBHelper.setDatabaseForTest(null);
  });

  test('loadPeerIdentityFromDb uses publicKeyPem when identityJson empty',
      () async {
    final peer = await IdentityKeyPair.generate();
    final identityJson = jsonEncode(await peer.toPublicJson());

    await DBHelper.insertOrUpdateUser({
      'id': 'peer.onion',
      'name': 'Peer',
      'identityJson': '',
      'publicKeyPem': identityJson,
    });

    final loaded = await loadPeerIdentityFromDb(keyManager, 'peer.onion');

    expect(loaded, isNotNull);
    expect(
      loaded!.fingerprint,
      IdentityKeyPair.fingerprintFromPublicJson(await peer.toPublicJson()),
    );
  });

  test('storedPeerIdentityRaw ignores legacy PEM payloads', () {
    expect(
      IdentityKeyPair.storedPeerIdentityRaw('-----BEGIN PUBLIC KEY-----', null),
      '-----BEGIN PUBLIC KEY-----',
    );
    expect(
      keyManager.tryImportPeerIdentity('-----BEGIN PUBLIC KEY-----'),
      isNull,
    );
  });
}
