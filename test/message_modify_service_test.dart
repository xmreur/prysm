// Tests for MessageModifyService visibility of inbound modify failures and
// honest delete propagation results.
//
// Covering:
// * an inbound modify whose envelope cannot be authenticated/decrypted is
//   reported as `InboundModifyOutcome.decryptFailed` (never silently dropped
//   while the sender is acked);
// * a successful delete-for-everyone still applies the tombstone exactly as
//   before (no regression);
// * `deleteMessage` returns false when propagation was never attempted
//   (unknown peer identity / no override) instead of a hardcoded `true`;
// * a failed direct post is queued for retry and is NOT reported as a
//   delivered propagation: the queued row keeps at-least-once delivery while
//   `deleteMessage` honestly reports the not-yet-delivered outcome;
// * a 4xx on the HTTP path (peer reachable but rejecting) surfaces as a
//   failed delete, end to end through the production transport wiring;
// * an inbound delete for a message the peer no longer has is acked as a
//   benign no-op (2xx) so the sender does not queue an unbounded retry.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/client/TorHttpClient.dart';
import 'package:prysm/constants/group_constants.dart';
import 'package:prysm/crypto/identity.dart';
import 'package:prysm/crypto/ratchet/session_store.dart';
import 'package:prysm/database/message_reactions.dart';
import 'package:prysm/database/message_schema_migrations.dart';
import 'package:prysm/database/messages.dart';
import 'package:prysm/server/inbound_message_router.dart';
import 'package:prysm/services/message_modify_service.dart';
import 'package:prysm/services/settings_service.dart';
import 'package:prysm/transport/tor_http_transport.dart';
import 'package:prysm/transport/transport_provider.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/message_modify_payload.dart';
import 'package:prysm/util/pending_message_db_helper.dart';
import 'package:prysm/util/tor_delivery.dart';
import 'package:prysm/util/tor_lifecycle_state.dart';
import 'package:prysm/util/tor_runtime_gate.dart';
import 'package:prysm/util/tor_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void _mockPathProvider() {
  final tempDir =
      Directory.systemTemp.createTempSync('prysm_msg_modify_svc_test_');
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async => tempDir.path);
}

Future<Database> _openMessagesDb() async {
  final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
  await db.execute('''
    CREATE TABLE messages(
      id TEXT PRIMARY KEY,
      senderId TEXT NOT NULL,
      receiverId TEXT NOT NULL,
      message TEXT,
      type TEXT,
      fileName TEXT,
      fileSize INTEGER,
      timestamp INTEGER NOT NULL,
      status TEXT DEFAULT 'sent',
      replyTo TEXT,
      readAt INTEGER,
      viewOnce INTEGER DEFAULT 0,
      viewed INTEGER DEFAULT 0,
      groupId TEXT,
      deletedAt INTEGER,
      editedAt INTEGER,
      expiresAt INTEGER
    )
  ''');
  await MessageReactionsDb.createTable(db);
  await MessageSchemaMigrations.createMessageSearchFtsTable(db);
  return db;
}

Future<Database> _openPendingDb() async {
  final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
  await db.execute('''
    CREATE TABLE pending_messages(
      id TEXT PRIMARY KEY,
      senderId TEXT,
      receiverId TEXT,
      message TEXT,
      type TEXT,
      fileName TEXT,
      fileSize INTEGER,
      timestamp INTEGER,
      status TEXT,
      replyTo TEXT,
      viewOnce INTEGER DEFAULT 0,
      groupId TEXT,
      targetMemberId TEXT
    )
  ''');
  return db;
}

Future<Database> _openDbHelperDb() async {
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
  await RatchetSessionStore.ensureTable(db);
  return db;
}

/// Public half of an [IdentityKeyPair], as the peer would see it.
Future<IdentityPublicKeys> _publicKeysOf(IdentityKeyPair pair) async {
  final publicJson = await pair.toPublicJson();
  return IdentityPublicKeys(
    signPublic: await pair.signPublicKey,
    agreePublic: await pair.agreePublicKey,
    fingerprint: IdentityKeyPair.fingerprintFromPublicJson(publicJson),
  );
}

Future<void> _insertSentMessage(String wireId) async {
  await MessagesDb.insertMessage({
    'id': wireId,
    'senderId': 'me.onion',
    'receiverId': 'peer.onion',
    'message': 'cipher',
    'type': 'text',
    'status': 'sent',
    'timestamp': 1,
  });
}

/// [TorHttpClient] whose [post] answers with a canned response, so the
/// production [TorHttpTransport.postJson] status handling is exercised
/// through the real transport wiring without a live Tor circuit. The
/// inherited [TorHttpClient.readUtf8Body] is the production body reader.
class _FakeTorHttpClient extends TorHttpClient {
  _FakeTorHttpClient(this.response)
      : super(proxyHost: '127.0.0.1', proxyPort: 9050);

  final HttpClientResponse response;

  @override
  Future<HttpClientResponse> post(
    Uri uri,
    Map<String, String> headers,
    String body,
  ) async =>
      response;
}

/// Minimal [HttpClientResponse]: only [statusCode] and the byte stream
/// consumed by [TorHttpClient.readUtf8Body] are implemented; every other
/// member falls through to [Object.noSuchMethod].
class _FakeHttpClientResponse implements HttpClientResponse {
  _FakeHttpClientResponse(this.statusCode, this.body);

  @override
  final int statusCode;

  final String body;

  @override
  Stream<S> transform<S>(StreamTransformer<List<int>, S> transformer) =>
      Stream<List<int>>.value(utf8.encode(body)).transform(transformer);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    _mockPathProvider();
  });

  late Database messagesDb;
  late Database pendingDb;
  late Database dbHelperDb;
  late KeyManager keyManager;

  setUp(() async {
    messagesDb = await _openMessagesDb();
    MessagesDb.setDatabaseForTest(messagesDb);

    pendingDb = await _openPendingDb();
    PendingMessageDbHelper.setDatabaseForTest(pendingDb);

    dbHelperDb = await _openDbHelperDb();
    DBHelper.setDatabaseForTest(dbHelperDb);

    keyManager = KeyManager.fromIdentity(await IdentityKeyPair.generate());
  });

  tearDown(() async {
    await messagesDb.close();
    MessagesDb.setDatabaseForTest(null);

    await pendingDb.close();
    PendingMessageDbHelper.setDatabaseForTest(null);

    await dbHelperDb.close();
    DBHelper.setDatabaseForTest(null);

    MessageModifyService.postDirectOverride = null;
    MessageModifyService.testPostman = null;
  });

  group('applyInbound visibility', () {
    test(
        'an inbound modify whose envelope cannot be authenticated is '
        'reported as decryptFailed, not silently dropped', () async {
      final sender = await IdentityKeyPair.generate();
      final publicJson = jsonEncode(await sender.toPublicJson());
      await DBHelper.insertOrUpdateUser({
        'id': 'peer.onion',
        'name': 'Peer',
        'identityJson': publicJson,
        'publicKeyPem': publicJson,
      });
      // Legacy unsigned dh-aead envelope, as sent by peers on <=v0.6.3: the
      // ratchet rejects it with FormatException('Unsigned peer message
      // rejected') before any decrypt step.
      const legacyEnvelope =
          '{"crypto":"v2","scheme":"dh-aead-1","ephemeralPub":"AA==",'
          '"nonce":"AA==","ciphertext":"AA=="}';

      final outcome = await MessageModifyService.applyInbound(
        keyManager: keyManager,
        localUserId: 'me.onion',
        encrypted: legacyEnvelope,
        senderId: 'peer.onion',
        type: messageModifyType,
      );

      expect(outcome, InboundModifyOutcome.decryptFailed);
    });

    test('an inbound modify for an unknown target row reports unknownTarget',
        () async {
      final sender = await IdentityKeyPair.generate();
      final receiver = await IdentityKeyPair.generate();
      final receiverKm = KeyManager.fromIdentity(receiver);
      final senderKm = KeyManager.fromIdentity(sender);
      final publicJson = jsonEncode(await sender.toPublicJson());
      await DBHelper.insertOrUpdateUser({
        'id': 'peer.onion',
        'name': 'Peer',
        'identityJson': publicJson,
        'publicKeyPem': publicJson,
      });
      final encrypted = await senderKm.encryptHybridForPeer(
        const MessageModifyPayload(
          targetMessageId: 'never-existed',
          action: 'delete',
          modifiedAt: 5,
        ).encode(),
        await _publicKeysOf(receiver),
        peerId: 'me.onion',
      );

      final outcome = await MessageModifyService.applyInbound(
        keyManager: receiverKm,
        localUserId: 'me.onion',
        encrypted: encrypted,
        senderId: 'peer.onion',
        type: messageModifyType,
      );

      expect(outcome, InboundModifyOutcome.unknownTarget);
    });

    test('an inbound modify for another sender\'s row reports ownershipRejected',
        () async {
      final sender = await IdentityKeyPair.generate();
      final receiver = await IdentityKeyPair.generate();
      final receiverKm = KeyManager.fromIdentity(receiver);
      final senderKm = KeyManager.fromIdentity(sender);
      final publicJson = jsonEncode(await sender.toPublicJson());
      await DBHelper.insertOrUpdateUser({
        'id': 'peer.onion',
        'name': 'Peer',
        'identityJson': publicJson,
        'publicKeyPem': publicJson,
      });
      const wireId = 'wire-foreign';
      await MessagesDb.insertMessage({
        'id': wireId,
        'senderId': 'other.onion',
        'receiverId': 'me.onion',
        'message': 'cipher',
        'type': 'text',
        'status': 'sent',
        'timestamp': 1,
      });
      final encrypted = await senderKm.encryptHybridForPeer(
        const MessageModifyPayload(
          targetMessageId: wireId,
          action: 'delete',
          modifiedAt: 5,
        ).encode(),
        await _publicKeysOf(receiver),
        peerId: 'me.onion',
      );

      final outcome = await MessageModifyService.applyInbound(
        keyManager: receiverKm,
        localUserId: 'me.onion',
        encrypted: encrypted,
        senderId: 'peer.onion',
        type: messageModifyType,
      );

      expect(outcome, InboundModifyOutcome.ownershipRejected);
    });
  });

  group('deleteMessage propagation result', () {
    test('a successful delete still applies the tombstone exactly as before',
        () async {
      const wireId = 'wire-ok';
      await _insertSentMessage(wireId);
      MessageModifyService.postDirectOverride = ({
        required id,
        required encrypted,
        required timestamp,
        required peerId,
      }) async =>
          true;

      final service = MessageModifyService.direct(
        userId: 'me.onion',
        keyManager: keyManager,
        peerId: 'peer.onion',
      );
      final ok = await service.deleteMessage(targetMessageId: wireId);

      expect(ok, isTrue);
      final rows = await MessagesDb.getMessageById(wireId);
      expect(rows, hasLength(1));
      expect(rows.first['deletedAt'], isNotNull);
    });

    test('deleteMessage reports false when propagation was never attempted',
        () async {
      const wireId = 'wire-nope';
      await _insertSentMessage(wireId);
      // No stored peer identity and no override: the send path cannot
      // encrypt, so nothing is attempted and nothing is queued.
      final service = MessageModifyService.direct(
        userId: 'me.onion',
        keyManager: keyManager,
        peerId: 'peer.onion',
      );
      final ok = await service.deleteMessage(targetMessageId: wireId);

      expect(ok, isFalse);
      // The local tombstone still applies; only the propagation is reported.
      final rows = await MessagesDb.getMessageById(wireId);
      expect(rows, hasLength(1));
      expect(rows.first['deletedAt'], isNotNull);
    });

    test('a failed direct post is queued for retry but NOT reported as '
        'propagated', () async {
      const wireId = 'wire-queued';
      await _insertSentMessage(wireId);
      MessageModifyService.postDirectOverride = ({
        required id,
        required encrypted,
        required timestamp,
        required peerId,
      }) async =>
          false;

      final service = MessageModifyService.direct(
        userId: 'me.onion',
        keyManager: keyManager,
        peerId: 'peer.onion',
      );
      final ok = await service.deleteMessage(targetMessageId: wireId);

      // The peer did not confirm the delete right now: the real transport
      // result must be reported, even though the row is queued for a later
      // retry (at-least-once delivery is preserved, the outcome is honest).
      expect(ok, isFalse);
      final pending = await PendingMessageDbHelper.getPendingDirectMessagesForReceiver(
        senderId: 'me.onion',
        receiverId: 'peer.onion',
      );
      expect(
        pending.where((row) => row['type'] == messageModifyType),
        hasLength(1),
      );
    });
  });

  group('delete propagation over the HTTP path', () {
    test('a 4xx on the HTTP transport is NOT reported as a successful delete',
        () async {
      const wireId = 'wire-http-reject';
      await _insertSentMessage(wireId);

      // Store the peer identity so the modify is encrypted for a real send
      // through the production postman (no test override on this path).
      final peer = await IdentityKeyPair.generate();
      final publicJson = jsonEncode(await peer.toPublicJson());
      await DBHelper.insertOrUpdateUser({
        'id': 'peer.onion',
        'name': 'Peer',
        'identityJson': publicJson,
        'publicKeyPem': publicJson,
      });

      // Production TransportProvider wiring: the peer is not WS-connected, so
      // postMessageOrFallback takes the HTTP fallback, whose postJson answers
      // with a 400 through the fake client.
      TransportProvider.configure(
        TorManager(
          torPath: '/bin/false',
          dataDir: '/tmp/prysm-modify-http-test',
          controlPassword: 'test-password',
        ),
      );
      TorHttpTransport.clientFactory = () => _FakeTorHttpClient(
        _FakeHttpClientResponse(
          400,
          '{"error":"Message modify target not found"}',
        ),
      );
      // The production HTTP path gates on the runtime gate; the default test
      // lifecycle is `stopped`, which would fail the send for the wrong
      // reason.
      TorRuntimeGate.resetForTest();

      try {
        final service = MessageModifyService.direct(
          userId: 'me.onion',
          keyManager: keyManager,
          peerId: 'peer.onion',
        );
        final ok = await service.deleteMessage(targetMessageId: wireId);

        expect(ok, isFalse);
        // The rejection is queued for a later retry, not dropped.
        final pending =
            await PendingMessageDbHelper.getPendingDirectMessagesForReceiver(
          senderId: 'me.onion',
          receiverId: 'peer.onion',
        );
        expect(
          pending.where((row) => row['type'] == messageModifyType),
          hasLength(1),
        );
      } finally {
        TransportProvider.resetForTest();
        TorHttpTransport.clientFactory = null;
        TorDelivery.resetForTest();
        TorRuntimeGate.resetForTest(lifecycle: TorLifecycleState.stopped);
      }
    });
  });

  group('unknown target handling', () {
    test('a delete for a message the peer no longer has is acked as a '
        'benign no-op, not a retryable 4xx', () async {
      final sender = await IdentityKeyPair.generate();
      final receiver = await IdentityKeyPair.generate();
      final receiverKm = KeyManager.fromIdentity(receiver);
      final senderKm = KeyManager.fromIdentity(sender);
      final publicJson = jsonEncode(await sender.toPublicJson());
      await DBHelper.insertOrUpdateUser({
        'id': 'peer.onion',
        'name': 'Peer',
        'identityJson': publicJson,
        'publicKeyPem': publicJson,
      });
      final encrypted = await senderKm.encryptHybridForPeer(
        const MessageModifyPayload(
          targetMessageId: 'never-existed',
          action: 'delete',
          modifiedAt: 5,
        ).encode(),
        await _publicKeysOf(receiver),
        peerId: 'me.onion',
      );

      final router = InboundMessageRouter(
        keyManager: receiverKm,
        settings: SettingsService(),
        localOnionAddress: () => 'me.onion',
      );
      final result = await router.handleMessage({
        'id': 'modify-event-1',
        'senderId': 'peer.onion',
        'receiverId': 'me.onion',
        'message': encrypted,
        'type': messageModifyType,
        'timestamp': 5,
      });

      // 2xx, not 4xx: the sender's transport must not queue an unbounded
      // retry of a rejection that can never succeed.
      expect(result.statusCode, 200);
    });
  });
}
