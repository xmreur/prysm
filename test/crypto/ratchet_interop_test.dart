import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/crypto/crypto.dart';
import 'package:prysm/services/peer_identity_resolver.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<IdentityPublicKeys> _publicKeys(IdentityKeyPair id) async {
  final sign = await id.signPublicKey;
  final agree = await id.agreePublicKey;
  return IdentityPublicKeys(
    signPublic: sign,
    agreePublic: agree,
    fingerprint: IdentityKeyPair.fingerprintFromPublicJson(
      await id.toPublicJson(),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    CryptoKeyStore.setUseInMemoryStorageOnly(true);
  });

  tearDownAll(() {
    CryptoKeyStore.setUseInMemoryStorageOnly(false);
  });

  late Database db;

  setUp(() async {
    CryptoKeyStore.resetInMemoryStorageForTest();
    db = await databaseFactory.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, _) async {
          await RatchetSessionStore.ensureTable(db);
          // Mirrors DBHelper._createDB so the send path can consult the
          // persisted per-peer ratchet-scheme cache (users.ratchetScheme).
          await db.execute('''
            CREATE TABLE users (
              id TEXT PRIMARY KEY,
              name TEXT,
              avatarUrl TEXT,
              avatarBase64 TEXT,
              customName TEXT,
              publicKeyPem TEXT,
              identityJson TEXT,
              ratchetScheme TEXT
            )
          ''');
        },
      ),
    );
    DBHelper.setDatabaseForTest(db);
    await RatchetSessionStore(db).deleteAll();
    RatchetService.instance.setPeerRatchetSchemeFetcherForTest(null);
  });

  tearDown(() async {
    RatchetService.instance.setPeerRatchetSchemeFetcherForTest(null);
    // Close the database: sqflite_common_ffi caches inMemoryDatabasePath
    // (singleInstance is the default), so without a close the next setUp's
    // openDatabase returns THIS database and earlier tests' users rows
    // (including ratchetScheme) leak into the next test's "cold" cache.
    await db.close();
    DBHelper.setDatabaseForTest(null);
  });

  group('Ratchet wire-scheme interop', () {
    test('unknown peer bootstraps v2 and emits ratchet-1', () async {
      final alice = await IdentityKeyPair.generate();
      final bob = await IdentityKeyPair.generate();
      final alicePub = await _publicKeys(alice);
      final bobPub = await _publicKeys(bob);
      const aliceOnion = 'alice.peer.onion';
      const bobOnion = 'bob.peer.onion';

      final bobBundle = await PrekeyBundle.generate(bob, persist: true);

      final wire = await RatchetService.instance.encryptText(
        peerId: bobOnion,
        plaintext: 'hello old peer',
        local: alice,
        peer: bobPub,
        peerBundle: bobBundle,
      );

      final envelope = jsonDecode(wire) as Map<String, dynamic>;
      expect(envelope['scheme'], CryptoConstants.schemeRatchet1);

      final plain = await RatchetService.instance.decryptText(
        peerId: aliceOnion,
        wire: wire,
        local: bob,
        peer: alicePub,
      );
      expect(plain, 'hello old peer');

      final session = await RatchetSessionStore(await DBHelper.database)
          .load(bobOnion);
      expect(session!.version, 2);
    });

    test('profile ratchet-3 bootstraps v3 session', () async {
      final alice = await IdentityKeyPair.generate();
      final bob = await IdentityKeyPair.generate();
      final alicePub = await _publicKeys(alice);
      final bobPub = await _publicKeys(bob);
      const aliceOnion = 'alice.peer.onion';
      const bobOnion = 'bob.peer.onion';

      final bobBundle = await PrekeyBundle.generate(bob, persist: true);

      // The profile fetch has already recorded ratchet-3 on the users row
      // (ContactAddService / PeerIdentityResolver / chat refresh all do
      // this); the send path must negotiate v3 from that cache.
      await DBHelper.ensureUserExist(bobOnion);
      await DBHelper.updateUserFields(bobOnion, {
        'ratchetScheme': CryptoConstants.schemeRatchet3,
      });

      final wire = await RatchetService.instance.encryptText(
        peerId: bobOnion,
        plaintext: 'hello v3 peer',
        local: alice,
        peer: bobPub,
        peerBundle: bobBundle,
      );

      final envelope = jsonDecode(wire) as Map<String, dynamic>;
      expect(envelope['scheme'], CryptoConstants.schemeRatchet3);

      final plain = await RatchetService.instance.decryptText(
        peerId: aliceOnion,
        wire: wire,
        local: bob,
        peer: alicePub,
      );
      expect(plain, 'hello v3 peer');

      final session = await RatchetSessionStore(await DBHelper.database)
          .load(bobOnion);
      expect(session!.version, 3);
    });

    test('peer identity resolver parses ratchetScheme from profile', () {
      expect(
        PeerIdentityResolver.ratchetSchemeFromProfile({
          'ratchetScheme': CryptoConstants.schemeRatchet3,
        }),
        CryptoConstants.schemeRatchet3,
      );
      expect(
        PeerIdentityResolver.ratchetSchemeFromProfile({
          'ratchetScheme': 'bogus',
        }),
        isNull,
      );
    });
  });
}
