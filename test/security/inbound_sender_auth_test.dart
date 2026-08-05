import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/crypto/crypto.dart';
import 'package:prysm/server/inbound_message_router.dart';
import 'package:prysm/services/settings_service.dart';
import 'package:prysm/services/wake_hint_service.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/util/key_manager.dart';
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
  group('inbound sender auth', () {
    test('self-asserted local senderId is rejected on the network path',
        () async {
      final alice = await IdentityKeyPair.generate();
      final alicePub = await _publicKeys(alice);

      final outcome = await DirectMessageAuth.authenticateInboundDirect(
        senderId: 'me.onion',
        wire: 'dummy',
        type: 'text',
        localUserId: 'me.onion',
        keyManager: KeyManager(),
        resolveIdentity: (_) async => alicePub,
        fromNetwork: true,
      );
      expect(outcome, DirectAuthOutcome.rejected);
    });

    test('local senderId stays accepted for locally authored messages',
        () async {
      final alice = await IdentityKeyPair.generate();
      final alicePub = await _publicKeys(alice);

      final outcome = await DirectMessageAuth.authenticateInboundDirect(
        senderId: 'me.onion',
        wire: 'dummy',
        type: 'text',
        localUserId: 'me.onion',
        keyManager: KeyManager(),
        resolveIdentity: (_) async => alicePub,
        fromNetwork: false,
      );
      expect(outcome, DirectAuthOutcome.accepted);
    });

    test('validateSyncHintPayload requires a signature', () {
      final now = DateTime.now().millisecondsSinceEpoch;
      expect(
        WakeHintService.validateSyncHintPayload(
          {'senderId': 'peer.onion', 'timestamp': now},
          'me.onion',
        ),
        'signature required',
      );
      expect(
        WakeHintService.validateSyncHintPayload(
          {'senderId': 'peer.onion', 'timestamp': now, 'sig': ''},
          'me.onion',
        ),
        'signature required',
      );
    });

    test('validateSyncHintPayload accepts a well-formed signed payload', () {
      expect(
        WakeHintService.validateSyncHintPayload(
          {
            'senderId': 'peer.onion',
            'timestamp': DateTime.now().millisecondsSinceEpoch,
            'sig': 'dGVzdA==',
          },
          'me.onion',
        ),
        isNull,
      );
    });
  });

  group('InboundMessageRouter.handleSyncHint', () {
    late IdentityKeyPair alice;
    late IdentityPublicKeys alicePub;
    late InboundMessageRouter router;

    setUpAll(() {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    });

    setUp(() async {
      alice = await IdentityKeyPair.generate();
      alicePub = await _publicKeys(alice);
      final db = await databaseFactory.openDatabase(
        '${inMemoryDatabasePath}_${DateTime.now().microsecondsSinceEpoch}',
        options: OpenDatabaseOptions(
          version: 1,
          onCreate: (db, _) async {
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
          },
        ),
      );
      DBHelper.setDatabaseForTest(db);
      await db.insert('users', {'id': 'alice.onion', 'name': 'Alice'});

      router = InboundMessageRouter(
        keyManager: KeyManager(),
        settings: SettingsService(),
        localOnionAddress: () => 'local.onion',
        resolvePeerIdentity: (_) async => alicePub,
      );
    });

    tearDown(() {
      DBHelper.setDatabaseForTest(null);
      WakeHintService.instance.resetForTest();
    });

    test('accepts a signed hint from a known contact', () async {
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final sig = await PeerProof.sign(
        context: PeerProof.syncHintContext,
        senderOnion: 'alice.onion',
        receiverOnion: 'local.onion',
        timestampMs: timestamp,
        identity: alice,
      );

      final result = await router.handleSyncHint({
        'senderId': 'alice.onion',
        'timestamp': timestamp,
        'sig': sig,
      });

      expect(result.statusCode, 200);
      expect(result.jsonBody?['status'], 'ok');
    });

    test('rejects a hint signed by a different identity', () async {
      final mallory = await IdentityKeyPair.generate();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final sig = await PeerProof.sign(
        context: PeerProof.syncHintContext,
        senderOnion: 'alice.onion',
        receiverOnion: 'local.onion',
        timestampMs: timestamp,
        identity: mallory,
      );

      final result = await router.handleSyncHint({
        'senderId': 'alice.onion',
        'timestamp': timestamp,
        'sig': sig,
      });

      expect(result.statusCode, 403);
      expect(result.jsonBody?['error'], 'Unknown sender');
    });
  });
}
