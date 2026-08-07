// Task 3 (group invite mode): the single ingress change of the
// pending-invite flow.
//
// `GroupService.handleIncomingControlMessage` drops control messages from
// senders whose identity is not in the local user store (M2: never resolve
// the sender over the network on inbound traffic). The GroupInviteMode
// setting chooses what happens to a *group_invite* at that drop:
// contactsOnly drops it with nothing stored; holdAsRequest keeps exactly
// one opaque, still-encrypted `control-wrap-2` envelope per sender in
// GroupPendingInviteStore — never decrypted, never parsed, and never a
// reason to fetch anything.
//
// The fake HTTP layer is the same one the POLICY tests use: it serves the
// registered peer profiles, so a restored network identity-resolve would
// succeed (and these tests go red) instead of failing silently. It is inert
// while the DB-only resolve holds.
//
// Task 4 (group invite mode): promotion. Once the sender's identity is in
// the local user store, the held envelope is replayed through the
// authenticated path (`GroupInvitePromoter` -> `handleIncomingControlMessage`)
// — never decrypted while pending, never resolved over the network, and the
// row is gone whether the replay authenticates or not.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/constants/group_constants.dart';
import 'package:prysm/crypto/crypto.dart';
import 'package:prysm/database/conversation_preferences_db.dart';
import 'package:prysm/database/message_schema_migrations.dart';
import 'package:prysm/database/messages.dart';
import 'package:prysm/models/group_invite_mode.dart';
import 'package:prysm/server/inbound_message_router.dart';
import 'package:prysm/services/group_invite_promoter.dart';
import 'package:prysm/services/settings_service.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/util/group_pending_invite_store.dart';
import 'package:prysm/util/group_sender_index_store.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/tor_runtime_gate.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

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
  await GroupPendingInviteStore.ensureTable(db);
  return db;
}

/// Serves the peer profiles registered by the tests over fake HTTP.
///
/// The flutter_test binding replaces all outbound HTTP with an instant
/// empty 400. That would make a restored network identity-resolve (the
/// behavior the tests below forbid) fail silently and the tests would stay
/// green. This fake stands in for the Tor network instead: it serves the
/// registered profiles keyed by onion, so the tests only pass when the code
/// under test never performs that fetch. It is inert while the policy
/// holds — the DB-only resolve does no HTTP at all.
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

void main() {
  late Database messagesDb;
  late Database dbHelperDb;
  late InboundMessageRouter router;
  late IdentityKeyPair localIdentity;
  late Map<String, IdentityPublicKeys> peers;
  late List<String> fetched;

  // Profiles the fake network serves, keyed by onion — populated by the
  // tests so a restored network identity-resolve would succeed (and the
  // tests go red) instead of failing silently.
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
    // keeps the tests honest: only the DB-only gate may drop.
    TorRuntimeGate.resetForTest();
    localIdentity = await IdentityKeyPair.generate();
    peers = {};

    messagesDb = await _openMessagesDb();
    MessagesDb.setDatabaseForTest(messagesDb);

    dbHelperDb = await _openDbHelperDb();
    DBHelper.setDatabaseForTest(dbHelperDb);

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

  group('group invite mode', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      // Profiles registered by the tests are keyed by onion, so a profile
      // left behind by an earlier case would be served for a different
      // identity later. Each case starts clean.
      peerProfiles.clear();
    });

    tearDown(() async {
      await SettingsService().setGroupInviteMode(GroupInviteMode.holdAsRequest);
    });

    test(
      'contactsOnly: an invite from an unresolvable sender is dropped and '
      'nothing is stored', () async {
        await SettingsService().setGroupInviteMode(
          GroupInviteMode.contactsOnly,
        );
        final inviter = await IdentityKeyPair.generate();
        peerProfiles['stranger.onion'] =
            jsonEncode(await inviter.toPublicJson());

        final result = await router.handleMessage(await _inviteMessage(
          id: 'm1',
          inviterId: 'stranger.onion',
          inviter: inviter,
          recipient: localIdentity,
          groupId: 'g1',
        ));

        expect(result.statusCode, 200);
        expect(await GroupPendingInviteStore.count(), 0);
        expect(await dbHelperDb.query('groups'), isEmpty);
        expect(fetched, isEmpty);
      },
    );

    test(
      'holdAsRequest: the same invite is held exactly once, and still creates '
      'no group and no fetch', () async {
        final inviter = await IdentityKeyPair.generate();
        peerProfiles['stranger.onion'] =
            jsonEncode(await inviter.toPublicJson());
        final invite = await _inviteMessage(
          id: 'm1',
          inviterId: 'stranger.onion',
          inviter: inviter,
          recipient: localIdentity,
          groupId: 'g1',
        );

        final result = await router.handleMessage(invite);
        // A retry of the same envelope must not create a second row.
        await router.handleMessage({...invite, 'id': 'm2'});

        expect(result.statusCode, 200);
        final rows = await GroupPendingInviteStore.pending();
        expect(rows, hasLength(1));
        expect(rows.single['senderId'], 'stranger.onion');
        expect(rows.single['wire'], invite['message']);
        expect(await dbHelperDb.query('groups'), isEmpty);
        expect(await dbHelperDb.query('group_members'), isEmpty);
        expect(await dbHelperDb.query('group_keys'), isEmpty);
        expect(fetched, isEmpty);
      },
    );

    test(
      'holdAsRequest: a failing pending-invite store degrades to the plain '
      'drop — the sender sees the same 200 as a drop', () async {
        await SettingsService().setGroupInviteMode(
          GroupInviteMode.holdAsRequest,
        );
        final inviter = await IdentityKeyPair.generate();
        peerProfiles['stranger.onion'] =
            jsonEncode(await inviter.toPublicJson());

        // Point the DB helper at a database that has no
        // group_pending_invites table — the real failure mode of a stale or
        // partial database — so hold() throws instead of writing. The
        // ingress must not turn that into a 500 the sender can observe: it
        // degrades to the drop.
        final brokenDb = await databaseFactory.openDatabase(
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
        DBHelper.setDatabaseForTest(brokenDb);

        final result = await router.handleMessage(await _inviteMessage(
          id: 'm1',
          inviterId: 'stranger.onion',
          inviter: inviter,
          recipient: localIdentity,
          groupId: 'g1',
        ));

        expect(result.statusCode, 200);
        // The exact ok-ack the plain drop answers with: status received and
        // no error key (the unguarded failure used to surface as a 500
        // {'error': ...} body instead).
        expect(result.jsonBody, containsPair('status', 'received'));
        expect(result.jsonBody, isNot(containsPair('error', anything)));
        await brokenDb.close();
      },
    );

    test(
      'holdAsRequest holds invites only: a key rotate from an unresolvable '
      'sender is dropped and stored nowhere', () async {
        final stranger = await IdentityKeyPair.generate();
        final result = await router.handleMessage({
          'id': 'm1',
          'senderId': 'stranger.onion',
          'receiverId': 'local.onion',
          'message': await GroupCryptoV2.encryptControlPayload(
            jsonEncode({'groupId': 'g1', 'keyVersion': 2}),
            stranger,
            await localIdentity.agreePublicKey,
          ),
          'type': groupKeyRotateType,
          'timestamp': 1000,
        });

        expect(result.statusCode, 200);
        expect(await GroupPendingInviteStore.count(), 0);
      },
    );

    group('promotion', () {
      test(
        'once the inviter identity is stored, the held invite applies and '
        'the row is gone', () async {
          final inviter = await IdentityKeyPair.generate();
          final invite = await _inviteMessage(
            id: 'm1',
            inviterId: 'stranger.onion',
            inviter: inviter,
            recipient: localIdentity,
            groupId: 'g1',
          );
          await router.handleMessage(invite);
          expect(await GroupPendingInviteStore.count(), 1);

          // What "the user added the contact" leaves behind.
          final json = jsonEncode(await inviter.toPublicJson());
          await DBHelper.insertOrUpdateUser({
            'id': 'stranger.onion',
            'name': 'Stranger',
            'identityJson': json,
            'publicKeyPem': json,
          });

          final promoter = GroupInvitePromoter(
            userId: 'local.onion',
            keyManager: KeyManager.fromIdentity(localIdentity),
          );
          expect(await promoter.promote('stranger.onion'), isTrue);

          expect(await GroupPendingInviteStore.count(), 0);
          expect((await dbHelperDb.query('groups')).single['id'], 'g1');
          expect(await dbHelperDb.query('group_members'), hasLength(2));
        },
      );

      test('a tampered held envelope is discarded and creates no group',
          () async {
        final inviter = await IdentityKeyPair.generate();
        final json = jsonEncode(await inviter.toPublicJson());
        await DBHelper.insertOrUpdateUser({
          'id': 'stranger.onion',
          'name': 'Stranger',
          'identityJson': json,
          'publicKeyPem': json,
        });
        await GroupPendingInviteStore.hold(
          senderId: 'stranger.onion',
          wire: 'not-a-control-envelope',
        );

        final promoter = GroupInvitePromoter(
          userId: 'local.onion',
          keyManager: KeyManager.fromIdentity(localIdentity),
        );
        expect(await promoter.promote('stranger.onion'), isFalse);

        expect(await GroupPendingInviteStore.count(), 0);
        expect(await dbHelperDb.query('groups'), isEmpty);
      });

      test('the sweep promotes only the senders that became resolvable',
          () async {
        final known = await IdentityKeyPair.generate();
        final unknown = await IdentityKeyPair.generate();
        await router.handleMessage(await _inviteMessage(
          id: 'm1',
          inviterId: 'known.onion',
          inviter: known,
          recipient: localIdentity,
          groupId: 'g1',
        ));
        await router.handleMessage(await _inviteMessage(
          id: 'm2',
          inviterId: 'unknown.onion',
          inviter: unknown,
          recipient: localIdentity,
          groupId: 'g2',
        ));
        final json = jsonEncode(await known.toPublicJson());
        await DBHelper.insertOrUpdateUser({
          'id': 'known.onion',
          'name': 'Known',
          'identityJson': json,
          'publicKeyPem': json,
        });

        final promoted = await GroupInvitePromoter(
          userId: 'local.onion',
          keyManager: KeyManager.fromIdentity(localIdentity),
        ).promoteResolvable();

        expect(promoted, 1);
        expect((await dbHelperDb.query('groups')).single['id'], 'g1');
        final rows = await GroupPendingInviteStore.pending();
        expect(rows.single['senderId'], 'unknown.onion');
      });
    });
  });
}
