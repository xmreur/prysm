import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/crypto/crypto.dart';
import 'package:prysm/database/conversation_preferences_db.dart';
import 'package:prysm/database/message_schema_migrations.dart';
import 'package:prysm/database/messages.dart';
import 'package:prysm/server/inbound_message_router.dart';
import 'package:prysm/services/settings_service.dart';
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
  TestWidgetsFlutterBinding.ensureInitialized();

  late Database dbHelperDb;
  late Database messagesDb;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    dbHelperDb = await databaseFactory.openDatabase(
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
          await ConversationPreferencesDb.createTable(db);
        },
      ),
    );
    DBHelper.setDatabaseForTest(dbHelperDb);

    messagesDb = await databaseFactory.openDatabase(
      '${inMemoryDatabasePath}_${DateTime.now().microsecondsSinceEpoch}',
      options: OpenDatabaseOptions(
        version: MessageSchemaMigrations.dbVersion,
        onCreate: MessageSchemaMigrations.onCreate,
      ),
    );
    MessagesDb.setDatabaseForTest(messagesDb);
  });

  tearDown(() async {
    DBHelper.setDatabaseForTest(null);
    MessagesDb.setDatabaseForTest(null);
    await dbHelperDb.close();
    await messagesDb.close();
  });

  group('M2: profile fetch is gated on DirectMessageAuth', () {
    test(
      'undecryptable DM from an unknown sender never fetches the sender profile',
      () async {
        final attacker = await IdentityKeyPair.generate();
        final victim = await IdentityKeyPair.generate();
        final victimAgree = await victim.agreePublicKey;

        // A real dm-signed envelope the victim cannot decrypt (the attacker's
        // identity is unknown, so no peer keys resolve).
        final wire = await CryptoWire.encryptSignedTextForPeer(
          'leak probe',
          attacker,
          victimAgree,
        );

        final fetched = <String>[];
        final router = InboundMessageRouter(
          keyManager: KeyManager.fromIdentity(victim),
          settings: SettingsService(),
          localOnionAddress: () => 'local.onion',
          fetchSenderProfile: (senderId) => fetched.add(senderId),
          // Unknown sender: no identity to resolve.
          resolvePeerIdentity: (_) async => null,
        );

        final result = await router.processMessage({
          'id': 'msg-undecryptable-1',
          'senderId': 'attacker.onion',
          'receiverId': 'local.onion',
          'message': wire,
          'type': 'text',
          'timestamp': 1,
        });

        expect(result.statusCode, 400);
        expect(fetched, isEmpty);
      },
    );

    test(
      'authenticated DM from a known contact still fetches the sender profile',
      () async {
        final alice = await IdentityKeyPair.generate();
        final bob = await IdentityKeyPair.generate();
        final alicePub = await _publicKeys(alice);
        final bobAgree = await bob.agreePublicKey;

        final wire = await CryptoWire.encryptSignedTextForPeer(
          'hello',
          alice,
          bobAgree,
        );

        final fetched = <String>[];
        final router = InboundMessageRouter(
          keyManager: KeyManager.fromIdentity(bob),
          settings: SettingsService(),
          localOnionAddress: () => 'local.onion',
          fetchSenderProfile: (senderId) => fetched.add(senderId),
          resolvePeerIdentity: (_) async => alicePub,
        );

        final result = await router.processMessage({
          'id': 'msg-authenticated-1',
          'senderId': 'alice.onion',
          'receiverId': 'local.onion',
          'message': wire,
          'type': 'text',
          'timestamp': 1,
        });

        expect(result.statusCode, 200);
        expect(fetched, ['alice.onion']);
      },
    );
  });
}
