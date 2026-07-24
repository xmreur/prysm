import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/crypto/identity.dart';
import 'package:prysm/services/peer_identity_resolver.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/tor_lifecycle_state.dart';
import 'package:prysm/util/tor_runtime_gate.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<Database> _openDbHelperDb() async {
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
  return db;
}

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  const peerId = 'peer.onion';

  late Database dbHelperDb;
  late KeyManager keyManager;
  late PeerIdentityResolver resolver;

  setUp(() async {
    dbHelperDb = await _openDbHelperDb();
    // PeerIdentityResolver's own IO (getUserById/insertOrUpdateUser) doesn't
    // touch the ratchet session store, so a plain users table suffices here.
    DBHelper.setDatabaseForTest(dbHelperDb);

    keyManager = KeyManager.fromIdentity(await IdentityKeyPair.generate());
    resolver = PeerIdentityResolver(peerId: peerId, keyManager: keyManager);

    TorRuntimeGate.resetForTest(lifecycle: TorLifecycleState.stopped);
  });

  tearDown(() async {
    await dbHelperDb.close();
    DBHelper.setDatabaseForTest(null);
    TorRuntimeGate.resetForTest();
  });

  group('getCachedIdentityJson', () {
    test('returns the identityJson cached for the peer', () async {
      await DBHelper.insertOrUpdateUser({
        'id': peerId,
        'name': 'Peer',
        'identityJson': '{"fake":"identity"}',
        'publicKeyPem': '{"fake":"identity"}',
      });

      final cached = await resolver.getCachedIdentityJson();

      expect(cached, '{"fake":"identity"}');
    });

    test('falls back to publicKeyPem when identityJson is absent', () async {
      await DBHelper.insertOrUpdateUser({
        'id': peerId,
        'name': 'Peer',
        'publicKeyPem': 'legacy-pem',
      });

      final cached = await resolver.getCachedIdentityJson();

      expect(cached, 'legacy-pem');
    });

    test('returns null when no user row exists', () async {
      final cached = await resolver.getCachedIdentityJson();
      expect(cached, isNull);
    });
  });

  group('fetchOverTor', () {
    test('returns null when the transport is blocked', () async {
      final resolved = await resolver.fetchOverTor();
      expect(resolved, isNull);
    });

    test(
      'pins pre-split behavior: partial identity is exposed via '
      'onIdentityResolved even when prekey parsing and the plain-identity '
      'fallback both fail',
      () async {
        TorRuntimeGate.resetForTest(lifecycle: TorLifecycleState.ready);

        final peerKeyPair = await IdentityKeyPair.generate();
        final peerIdentityJson = jsonEncode(await peerKeyPair.toPublicJson());

        final injectedResolver = PeerIdentityResolver(
          peerId: peerId,
          keyManager: keyManager,
          fetchProfile: (_) async => jsonEncode({
            'identityJson': peerIdentityJson,
            // Malformed prekey bundle: parseVerified will throw, sending
            // fetchOverTor down the plain-identity fallback path.
            'prekeyBundle': {'garbage': true},
          }),
          fetchPublic: (_) async => throw StateError('fallback also fails'),
        );

        IdentityPublicKeys? partialIdentity;
        final resolved = await injectedResolver.fetchOverTor(
          onIdentityResolved: (identity) => partialIdentity = identity,
        );

        expect(resolved, isNull);
        expect(partialIdentity, isNotNull);
        expect(partialIdentity!.fingerprint,
            IdentityKeyPair.fingerprintFromPublicJson(
                await peerKeyPair.toPublicJson()));
      },
    );
  });
}
