import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/crypto/ratchet/ratchet_session.dart';
import 'package:prysm/crypto/ratchet/session_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database db;
  late RatchetSessionStore store;

  setUp(() async {
    db = await databaseFactory.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, _) async {
          await RatchetSessionStore.ensureTable(db);
        },
      ),
    );
    store = RatchetSessionStore(db);
  });

  tearDown(() async {
    await db.close();
  });

  Future<RatchetSession> sampleSession() async {
    final shared = Uint8List.fromList(List.generate(32, (i) => i));
    return RatchetSession.initializeAsInitiator(shared);
  }

  test('load returns null for unknown peer', () async {
    expect(await store.load('unknown.onion'), isNull);
  });

  test('save and load round trip', () async {
    final session = await sampleSession();
    await session.encryptMessage(utf8.encode('msg'));

    await store.save('peer.onion', session);
    final loaded = await store.load('peer.onion');

    expect(loaded, isNotNull);
    expect(loaded!.sendCounter, session.sendCounter);
    expect(loaded.recvCounter, session.recvCounter);
    expect(loaded.isInitiator, session.isInitiator);
    expect(loaded.sharedMaterial, session.sharedMaterial);
  });

  test('save overwrites existing session', () async {
    final session1 = await sampleSession();
    await store.save('peer.onion', session1);

    final updated = await sampleSession();
    await updated.encryptMessage(utf8.encode('first'));
    await updated.encryptMessage(utf8.encode('second'));
    await store.save('peer.onion', updated);

    final loaded = await store.load('peer.onion');
    expect(loaded!.sendCounter, updated.sendCounter);
    expect(loaded.sendCounter, greaterThan(session1.sendCounter));
  });

  test('delete removes a single session', () async {
    final session = await sampleSession();
    await store.save('peer.onion', session);
    await store.save('other.onion', session);

    await store.delete('peer.onion');

    expect(await store.load('peer.onion'), isNull);
    expect(await store.load('other.onion'), isNotNull);
  });

  test('deleteAll removes every session', () async {
    final session = await sampleSession();
    await store.save('peer1.onion', session);
    await store.save('peer2.onion', session);

    await store.deleteAll();

    expect(await store.load('peer1.onion'), isNull);
    expect(await store.load('peer2.onion'), isNull);
  });
}
