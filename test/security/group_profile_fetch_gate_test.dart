// Final whole-branch review, Important 1: M2 must stay closed on the GROUP
// chat paths.
//
// Task 5 gated the profile fetch for direct messages on DirectMessageAuth,
// but the group-chat path still fetched the sender profile BEFORE every
// gate: an unauthenticated attacker who knows the victim's onion could POST
// a group message (groupId != null — no group key, no membership needed)
// and the victim would issue GET /profile?requester=<victim-onion> to the
// attacker's onion — the same implicit delivery confirmation M2. The same
// leak existed on the group control path.
//
// RED/GREEN: every "no fetch" test fails on the pre-fix code (the spy is
// called) and passes after the fix. The gates (legacy-scheme, anti-replay,
// pre-join, control authentication) are fail-open by design for senders
// whose identity is not in the local user store, so the fetch is gated on
// the FETCH, not on the message: it fires only when the sender's identity
// is already known locally — a cache-only loadPeerIdentityFromDb, never a
// Tor fetch. Unknown senders' messages are still accepted and stored; only
// the outbound GET /profile is suppressed. The last test guards the good
// path: a valid envelope from a known member still triggers the fetch.
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/constants/group_constants.dart';
import 'package:prysm/crypto/crypto.dart';
import 'package:prysm/database/conversation_preferences_db.dart';
import 'package:prysm/database/message_schema_migrations.dart';
import 'package:prysm/database/messages.dart';
import 'package:prysm/server/inbound_message_router.dart';
import 'package:prysm/services/settings_service.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/util/group_sender_index_store.dart';
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

Future<Database> _openMessagesDb() async {
  return databaseFactory.openDatabase(
    '${inMemoryDatabasePath}_${DateTime.now().microsecondsSinceEpoch}',
    options: OpenDatabaseOptions(
      version: MessageSchemaMigrations.dbVersion,
      onCreate: MessageSchemaMigrations.onCreate,
    ),
  );
}

Future<Database> _openDbHelperDb() async {
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
        await db.execute('''
          CREATE TABLE group_members (
            groupId TEXT NOT NULL,
            memberId TEXT NOT NULL,
            role TEXT NOT NULL,
            joinedAt INTEGER NOT NULL,
            PRIMARY KEY (groupId, memberId)
          )
        ''');
        await ConversationPreferencesDb.createTable(db);
      },
    ),
  );
  await GroupSenderIndexStore.ensureTable(db);
  return db;
}

Uint8List _groupKey() => Uint8List.fromList(List.generate(32, (i) => i));

/// Builds a group chat message whose `message` field is a legacy
/// `group-aead-1` envelope (AES-GCM with the shared group key, no sender
/// binding) — the payload an unauthenticated attacker POSTs under their own
/// claimed [senderId].
Future<Map<String, dynamic>> _legacyGroupMessage({
  required String id,
  required String senderId,
  required String groupId,
  String plaintext = 'hello',
  int timestamp = 1000,
}) async {
  final wire = await GroupCryptoV2.encryptText(_groupKey(), plaintext);
  return {
    'id': id,
    'senderId': senderId,
    'receiverId': 'local.onion',
    'message': wire,
    'type': groupTextType,
    'groupId': groupId,
    'timestamp': timestamp,
  };
}

/// Builds a group chat message whose `message` field is a signed group
/// sender-key envelope with the given [index], signed by [sender].
Future<Map<String, dynamic>> _senderKeyGroupMessage({
  required String id,
  required IdentityKeyPair sender,
  required String envelopeSenderId,
  required String transportSenderId,
  required String groupId,
  required int index,
  int timestamp = 1000,
}) async {
  final wire = await GroupCryptoV2.encryptWithSenderKey(
    epochKey: _groupKey(),
    groupId: groupId,
    senderId: envelopeSenderId,
    messageIndex: index,
    plaintext: 'hello-$index',
    sender: sender,
  );
  return {
    'id': id,
    'senderId': transportSenderId,
    'receiverId': 'local.onion',
    'message': wire,
    'type': groupTextType,
    'groupId': groupId,
    'timestamp': timestamp,
  };
}

void main() {
  late Database messagesDb;
  late Database dbHelperDb;
  late InboundMessageRouter router;
  late IdentityKeyPair alice;
  late Map<String, IdentityPublicKeys> peers;
  late List<String> fetched;

  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    alice = await IdentityKeyPair.generate();
    peers = {
      'alice.onion': await _publicKeys(alice),
    };

    messagesDb = await _openMessagesDb();
    MessagesDb.setDatabaseForTest(messagesDb);

    dbHelperDb = await _openDbHelperDb();
    DBHelper.setDatabaseForTest(dbHelperDb);
    // The anti-replay gate resolves the sender cache-only
    // (loadPeerIdentityFromDb): a member who is not in the local user store
    // is indistinguishable from an unknown sender.
    final aliceJson = jsonEncode(await alice.toPublicJson());
    await DBHelper.insertOrUpdateUser({
      'id': 'alice.onion',
      'name': 'Alice',
      'identityJson': aliceJson,
      'publicKeyPem': aliceJson,
    });

    fetched = [];
    router = InboundMessageRouter(
      keyManager: KeyManager(),
      settings: SettingsService(),
      localOnionAddress: () => 'local.onion',
      fetchSenderProfile: (senderId) => fetched.add(senderId),
      resolvePeerIdentity: (senderId) async => peers[senderId],
    );
  });

  tearDown(() async {
    // Claim ownership is process-global: a claim left by one case would
    // refuse the same triple in the next, so it must be cleared between
    // cases.
    GroupSenderIndexStore.resetForTest();
    await messagesDb.close();
    MessagesDb.setDatabaseForTest(null);

    await dbHelperDb.close();
    DBHelper.setDatabaseForTest(null);
  });

  group('M2: group-chat profile fetch is gated', () {
    test(
      'RED: a legacy group-aead envelope from an unknown sender is rejected '
      'with 400 and never fetches the sender profile (pre-fix: fetch fires '
      'before the legacy gate)', () async {
        final result = await router.handleMessage(
          await _legacyGroupMessage(
            id: 'm1',
            senderId: 'attacker.onion',
            groupId: 'g1',
          ),
        );

        expect(result.statusCode, 400);
        expect(fetched, isEmpty);
      },
    );

    test(
      'RED: an undecryptable sender-key envelope (envelope senderId != '
      'transport senderId) is acked-but-dropped and never fetches the sender '
      'profile (pre-fix: fetch fires before the anti-replay gate)',
      () async {
        final result = await router.handleMessage(
          await _senderKeyGroupMessage(
            id: 'm1',
            sender: alice,
            envelopeSenderId: 'alice.onion',
            transportSenderId: 'attacker.onion',
            groupId: 'g1',
            index: 0,
          ),
        );

        expect(result.statusCode, 200);
        expect(result.jsonBody?['status'], 'received');
        expect(fetched, isEmpty);

        final rows = await messagesDb.query('messages');
        expect(rows, isEmpty);
      },
    );

    test(
      'RED: a message older than the local user\u0027s join is acked-but-dropped '
      'and never fetches the sender profile (pre-fix: fetch fires before '
      'the pre-join drop)', () async {
        await dbHelperDb.insert('group_members', {
          'groupId': 'g1',
          'memberId': 'local.onion',
          'role': 'member',
          'joinedAt': 2000,
        });

        final result = await router.handleMessage(
          await _legacyGroupMessage(
            id: 'm1',
            senderId: 'attacker.onion',
            groupId: 'g1',
            timestamp: 1000,
          ),
        );

        expect(result.statusCode, 200);
        expect(result.jsonBody?['status'], 'received');
        expect(fetched, isEmpty);
      },
    );

    test(
      'RED: an unauthenticated group control payload never fetches the '
      'sender profile (pre-fix: fetch fires before the control payload '
      'authentication)', () async {
        final result = await router.handleMessage({
          'id': 'ctl-1',
          'senderId': 'alice.onion',
          'receiverId': 'local.onion',
          // Garbage: decryptControlPayload cannot verify a sender signature.
          'message': 'not-a-control-envelope',
          'type': groupInviteType,
          'timestamp': 1000,
        });

        // The control path acks idempotently regardless of payload validity,
        // but the fetch must not fire for traffic that failed authentication.
        expect(result.statusCode, 200);
        expect(fetched, isEmpty);
      },
    );

    test(
      'RED: a non-parseable (garbage) group envelope from an unknown sender '
      'is stored but never fetches the sender profile (pre-fix: the '
      'fail-open gates pass it through and the fetch fires anyway)',
      () async {
        final result = await router.handleMessage({
          'id': 'm1',
          'senderId': 'attacker.onion',
          'receiverId': 'local.onion',
          'message': 'garbage-not-an-envelope',
          'type': groupTextType,
          'groupId': 'g1',
          'timestamp': 1000,
        });

        // Accepted and stored exactly like today: the fetch is the only
        // thing suppressed for senders whose identity is not in the local
        // user store.
        expect(result.statusCode, 200);
        expect(result.jsonBody?['status'], 'received');
        expect(fetched, isEmpty);

        final rows = await messagesDb.query('messages');
        expect(rows, hasLength(1));
        expect(rows.single['senderId'], 'attacker.onion');
        expect(rows.single['groupId'], 'g1');
      },
    );

    test(
      'RED: a self-signed sender-key envelope from an unknown sender is '
      'stored but never fetches the sender profile (pre-fix: the fail-open '
      'anti-replay gate passes an unresolvable sender through and the fetch '
      'fires)',
      () async {
        final attacker = await IdentityKeyPair.generate();
        final result = await router.handleMessage(
          await _senderKeyGroupMessage(
            id: 'm1',
            sender: attacker,
            envelopeSenderId: 'attacker.onion',
            transportSenderId: 'attacker.onion',
            groupId: 'g1',
            index: 0,
          ),
        );

        expect(result.statusCode, 200);
        expect(result.jsonBody?['status'], 'received');
        expect(fetched, isEmpty);

        final rows = await messagesDb.query('messages');
        expect(rows, hasLength(1));
        expect(rows.single['senderId'], 'attacker.onion');
        expect(rows.single['groupId'], 'g1');
      },
    );

    test(
      'a valid signed sender-key envelope from a known member is stored and '
      'still fetches the sender profile (good path does not regress)',
      () async {
        final result = await router.handleMessage(
          await _senderKeyGroupMessage(
            id: 'm1',
            sender: alice,
            envelopeSenderId: 'alice.onion',
            transportSenderId: 'alice.onion',
            groupId: 'g1',
            index: 0,
            timestamp: 3000,
          ),
        );

        expect(result.statusCode, 200);
        expect(result.jsonBody?['status'], 'received');
        expect(fetched, ['alice.onion']);

        final rows = await messagesDb.query('messages');
        expect(rows, hasLength(1));
        expect(rows.single['senderId'], 'alice.onion');
        expect(rows.single['groupId'], 'g1');
      },
    );
  });
}
