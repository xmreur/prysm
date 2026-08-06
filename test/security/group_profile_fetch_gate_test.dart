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
import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
import 'package:prysm/util/tor_runtime_gate.dart';
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
            keyVersion INTEGER NOT NULL DEFAULT 1
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

/// Serves the peer profiles registered by the tests over fake HTTP.
///
/// The flutter_test binding replaces all outbound HTTP with an instant
/// empty 400. That would make a restored network identity-resolve (the
/// pre-PR behavior the POLICY tests below forbid) fail silently and the
/// tests would stay green. This fake stands in for the Tor network
/// instead: it serves the registered profiles keyed by onion, so the
/// POLICY tests only pass when the code under test never performs that
/// fetch. It is inert while the policy holds — the DB-only resolve does
/// no HTTP at all.
class _ProfileNetworkOverrides extends HttpOverrides {
  final Map<String, String> profilesByOnion;

  _ProfileNetworkOverrides(this.profilesByOnion);

  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      _FakeHttpClient(profilesByOnion);
}

class _FakeHttpClient implements HttpClient {
  final Map<String, String> profilesByOnion;

  _FakeHttpClient(this.profilesByOnion);

  @override
  Future<HttpClientRequest> getUrl(Uri url) async =>
      _FakeHttpClientRequest(profilesByOnion, url);

  @override
  Future<void> close({bool force = false}) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeHttpClientRequest implements HttpClientRequest {
  final Map<String, String> profilesByOnion;
  final Uri url;

  _FakeHttpClientRequest(this.profilesByOnion, this.url);

  @override
  final HttpHeaders headers = _FakeHttpHeaders();

  @override
  Future<HttpClientResponse> close() async =>
      _FakeHttpClientResponse(profilesByOnion, url);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeHttpHeaders implements HttpHeaders {
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeHttpClientResponse implements HttpClientResponse {
  final Map<String, String> profilesByOnion;
  final Uri url;

  _FakeHttpClientResponse(this.profilesByOnion, this.url);

  String? get _body => profilesByOnion[url.host];

  @override
  int get statusCode => _body == null ? 400 : 200;

  @override
  int get contentLength => _body?.length ?? 0;

  @override
  Stream<S> transform<S>(StreamTransformer<List<int>, S> transformer) =>
      Stream<List<int>>.fromIterable([utf8.encode(_body ?? '')])
          .transform(transformer);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// Builds a `control-wrap-2` group invite exactly as a legitimate inviter
/// sends it (`GroupControlChannel.sendInvite`): the fresh group key
/// encrypted for the local user, the whole payload signed by the inviter.
Future<Map<String, dynamic>> _inviteMessage({
  required String id,
  required String inviterId,
  required IdentityKeyPair inviter,
  required IdentityKeyPair recipient,
  required String groupId,
}) async {
  final recipientAgreePublic = await recipient.agreePublicKey;
  final groupKey = GroupCryptoV2.generateGroupKey();
  final encryptedGroupKey = await GroupCryptoV2.encryptGroupKeyForStorage(
    groupKey,
    inviter,
    peerAgreePublic: recipientAgreePublic,
  );
  final wire = await GroupCryptoV2.encryptControlPayload(
    jsonEncode({
      'groupId': groupId,
      'name': 'Invited Group',
      'createdBy': inviterId,
      'members': [
        {'id': 'local.onion', 'role': 'member'},
        {'id': inviterId, 'role': 'admin'},
      ],
      'encryptedGroupKey': encryptedGroupKey,
      'keyVersion': 1,
    }),
    inviter,
    recipientAgreePublic,
  );
  return {
    'id': id,
    'senderId': inviterId,
    'receiverId': 'local.onion',
    'message': wire,
    'type': groupInviteType,
    'timestamp': 1000,
  };
}

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
  late IdentityKeyPair localIdentity;
  late IdentityKeyPair alice;
  late Map<String, IdentityPublicKeys> peers;
  late List<String> fetched;

  // Profiles the fake network serves, keyed by onion — populated by the
  // POLICY tests so a restored network identity-resolve would succeed
  // (and the tests go red) instead of failing silently.
  final peerProfiles = <String, String>{};
  late HttpOverrides? originalOverrides;

  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    originalOverrides = HttpOverrides.current;
    HttpOverrides.global = _ProfileNetworkOverrides(peerProfiles);
  });

  tearDownAll(() {
    HttpOverrides.global = originalOverrides;
  });

  setUp(() async {
    // The Tor runtime gate starts `stopped`, which would silently block any
    // (forbidden) network identity-resolve — and mask a restored one. Ready
    // keeps the POLICY tests honest: only the DB-only gate may drop.
    TorRuntimeGate.resetForTest();
    localIdentity = await IdentityKeyPair.generate();
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
      keyManager: KeyManager.fromIdentity(localIdentity),
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

  // CR8 (accepted, option 1 — the PR owner's decision):
  // https://github.com/xmreur/prysm/pull/128#issuecomment-5205552544
  //
  // A first-contact invite — correctly signed by an inviter whose identity
  // is simply not in the local user store — is deliberately dropped: the
  // identity gate is DB-only, so the payload cannot even be authenticated,
  // and restoring a network resolve would reopen the M2 profile-fetch
  // oracle for unauthenticated senders. The pending-invite flow is tracked
  // separately. The pair below pins both halves: the drop (with the fake
  // network serving the inviter's identity, so a restored resolve would
  // succeed and fail the test), and the good path (identity stored ->
  // invite applied) so a broken invite path cannot mask a green.
  group(
    'POLICY: a first-contact invite is dropped without any profile fetch '
    '(accepted: option 1)',
    () {
      test(
        'POLICY: a correctly signed invite from an inviter whose identity '
        'is not in the local user store is acked but dropped: no group, no '
        'members, no profile fetch — even though the network could have '
        'served the inviter identity', () async {
          final inviter = await IdentityKeyPair.generate();
          const inviterId = 'inviter.onion';
          // The fake network would resolve the inviter if the code asked:
          // the test only passes because the DB-only resolve never asks.
          final inviterJson = jsonEncode(await inviter.toPublicJson());
          peerProfiles[inviterId] = jsonEncode({
            'identityJson': inviterJson,
            'publicKeyPem': inviterJson,
          });

          final result = await router.handleMessage(
            await _inviteMessage(
              id: 'ctl-2',
              inviterId: inviterId,
              inviter: inviter,
              recipient: localIdentity,
              groupId: 'g9',
            ),
          );

          // The sender cannot tell a drop from delivery: the ack is the
          // same as for an applied invite.
          expect(result.statusCode, 200);
          expect(result.jsonBody?['status'], 'received');
          // The drop happens before any fetch can fire.
          expect(fetched, isEmpty);
          // The invite never lands: no group row, no member rows, no key.
          expect(await DBHelper.getGroupById('g9'), isNull);
          final members = await dbHelperDb.query(
            'group_members',
            where: 'groupId = ?',
            whereArgs: ['g9'],
          );
          expect(members, isEmpty);
          final keys = await dbHelperDb.query(
            'group_keys',
            where: 'groupId = ?',
            whereArgs: ['g9'],
          );
          expect(keys, isEmpty);
        },
      );

      test(
        'POLICY: the same invite with the inviter identity stored locally '
        'IS applied (group created) — the drop above is the identity gate, '
        'not a broken invite path', () async {
          final inviter = await IdentityKeyPair.generate();
          const inviterId = 'inviter.onion';
          final inviterJson = jsonEncode(await inviter.toPublicJson());
          await DBHelper.insertOrUpdateUser({
            'id': inviterId,
            'name': 'Inviter',
            'identityJson': inviterJson,
            'publicKeyPem': inviterJson,
          });

          final result = await router.handleMessage(
            await _inviteMessage(
              id: 'ctl-3',
              inviterId: inviterId,
              inviter: inviter,
              recipient: localIdentity,
              groupId: 'g9',
            ),
          );

          expect(result.statusCode, 200);
          expect(result.jsonBody?['status'], 'received');
          final group = await DBHelper.getGroupById('g9');
          expect(group, isNotNull);
          expect(group?['name'], 'Invited Group');
          final members = await dbHelperDb.query(
            'group_members',
            where: 'groupId = ?',
            whereArgs: ['g9'],
          );
          expect(
            members.map((m) => m['memberId']),
            containsAll(['local.onion', inviterId]),
          );
          // The fetch fires only after the payload authenticated — the
          // good-path counterpart to the policy above.
          expect(fetched, [inviterId]);
        },
      );
    },
  );
}
