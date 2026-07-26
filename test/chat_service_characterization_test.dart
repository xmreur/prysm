// Characterization tests for the ChatService monolith (Fase 3.2), fixed
// against the CURRENT implementation before PeerIdentityResolver and
// PendingQueueReconciler are extracted. These must stay green across the
// extraction with no behavioral change.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/crypto/identity.dart';
import 'package:prysm/crypto/ratchet/session_store.dart';
import 'package:prysm/database/messages.dart';
import 'package:prysm/services/chat_service.dart';
import 'package:prysm/services/side_channel_postman.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/pending_message_db_helper.dart';
import 'package:prysm/util/tor_lifecycle_state.dart';
import 'package:prysm/util/tor_runtime_gate.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<Database> _openPendingDb() async {
  final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
  await db.execute('DROP TABLE IF EXISTS pending_messages');
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
  // ChatService.encryptForPeer routes through KeyManager into the shared
  // ratchet session store, which DBHelper.setDatabaseForTest wires onto
  // this same database (see db_helper.dart).
  await RatchetSessionStore.ensureTable(db);
  return db;
}

Future<Database> _openMessagesDb() async {
  final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
  await db.execute('DROP TABLE IF EXISTS messages');
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
      editedAt INTEGER
    )
  ''');
  return db;
}

class _FakePostmanCall {
  _FakePostmanCall({
    required this.peerId,
    required this.payload,
    required this.timeout,
  });

  final String peerId;
  final Map<String, dynamic> payload;
  final Duration timeout;
}

class _FakePostman implements SideChannelPostman {
  final directCalls = <_FakePostmanCall>[];

  @override
  Future<void> postDirect({
    required String peerId,
    required Map<String, dynamic> payload,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    directCalls.add(
      _FakePostmanCall(peerId: peerId, payload: payload, timeout: timeout),
    );
  }

  @override
  Future<void> postGroup({
    required String targetMemberId,
    required Map<String, dynamic> payload,
    Duration timeout = const Duration(seconds: 30),
  }) async {}
}

void main() {
  late Directory docsDir;

  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;

    // MessagesDb.getMessageById unconditionally probes MessageBlobStore,
    // which shells out to path_provider even for small inline payloads.
    docsDir = Directory.systemTemp.createTempSync('chat_service_char_test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async {
        if (call.method == 'getApplicationDocumentsDirectory') {
          return docsDir.path;
        }
        return null;
      },
    );
  });

  tearDownAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    docsDir.deleteSync(recursive: true);
  });


  const userId = 'me.onion';
  const peerId = 'peer.onion';

  late Database pendingDb;
  late Database dbHelperDb;
  late Database messagesDb;
  late KeyManager keyManager;
  late IdentityKeyPair peerKeyPair;
  late String peerIdentityJson;

  setUp(() async {
    pendingDb = await _openPendingDb();
    PendingMessageDbHelper.setDatabaseForTest(pendingDb);

    dbHelperDb = await _openDbHelperDb();
    DBHelper.setDatabaseForTest(dbHelperDb);

    messagesDb = await _openMessagesDb();
    MessagesDb.setDatabaseForTest(messagesDb);

    peerKeyPair = await IdentityKeyPair.generate();
    keyManager = KeyManager.fromIdentity(await IdentityKeyPair.generate());
    peerIdentityJson = jsonEncode(await peerKeyPair.toPublicJson());

    // Deterministic, network-free "send fails" path: ChatService checks
    // TorRuntimeGate.blocked before touching the transport, so blocking it
    // characterizes the pending-queue path without a real Tor socket.
    TorRuntimeGate.resetForTest(lifecycle: TorLifecycleState.stopped);
  });

  tearDown(() async {
    await pendingDb.close();
    PendingMessageDbHelper.setDatabaseForTest(null);

    await dbHelperDb.close();
    DBHelper.setDatabaseForTest(null);

    await messagesDb.close();
    MessagesDb.setDatabaseForTest(null);

    TorRuntimeGate.resetForTest();
  });

  Future<ChatService> serviceWithResolvedIdentity() async {
    final service = ChatService(
      userId: userId,
      peerId: peerId,
      keyManager: keyManager,
    );
    service.peerIdentity = IdentityPublicKeys(
      signPublic: await peerKeyPair.signPublicKey,
      agreePublic: await peerKeyPair.agreePublicKey,
      fingerprint: 'test',
    );
    return service;
  }

  group('sendTextMessage', () {
    test('queues the message for retry when the transport is blocked',
        () async {
      final service = await serviceWithResolvedIdentity();
      addTearDown(service.dispose);

      final id = await service.sendTextMessage('hello');
      expect(id, isNotNull);

      final stored = await MessagesDb.getMessageById(id!);
      expect(stored, hasLength(1));
      expect(stored.first['status'], 'pending');

      final pending = await PendingMessageDbHelper.getPendingMessages(
        receiverId: peerId,
      );
      expect(pending, hasLength(1));
      expect(pending.first['id'], id);
      expect(pending.first['type'], 'text');
    });
  });

  group('reconcilePendingQueue', () {
    test('re-queues a message dropped from the pending table', () async {
      final service = await serviceWithResolvedIdentity();
      addTearDown(service.dispose);

      final id = await service.sendTextMessage('hello');
      expect(id, isNotNull);

      // Simulate the pending row being lost (app restart during send, etc.)
      // while the messages row is still marked pending.
      await PendingMessageDbHelper.removeMessages([id!]);
      expect(
        await PendingMessageDbHelper.getPendingMessages(receiverId: peerId),
        isEmpty,
      );

      await service.reconcilePendingQueue();

      final pending = await PendingMessageDbHelper.getPendingMessages(
        receiverId: peerId,
      );
      expect(pending, hasLength(1));
      expect(pending.first['id'], id);
      expect(pending.first['type'], 'text');
    });
  });

  group('initialize', () {
    test('resolves the peer identity cached in the users table', () async {
      await DBHelper.insertOrUpdateUser({
        'id': peerId,
        'name': 'Peer',
        'identityJson': peerIdentityJson,
        'publicKeyPem': peerIdentityJson,
      });

      final service = ChatService(
        userId: userId,
        peerId: peerId,
        keyManager: keyManager,
      );
      addTearDown(service.dispose);

      final ok = await service.initialize(null);

      expect(ok, isTrue);
      expect(service.peerIdentity, isNotNull);
      expect(
        service.peerIdentity!.fingerprint,
        IdentityKeyPair.fingerprintFromPublicKeys(
          await peerKeyPair.signPublicKeyBytes(),
          await peerKeyPair.agreePublicKeyBytes(),
        ),
      );
    });

    test('returns false when nothing is cached and the transport is blocked',
        () async {
      final service = ChatService(
        userId: userId,
        peerId: peerId,
        keyManager: keyManager,
      );
      addTearDown(service.dispose);

      final ok = await service.initialize(null);

      expect(ok, isFalse);
      expect(service.peerIdentity, isNull);
    });
  });

  group('processPendingForPeer', () {
    test('returns false when nothing is pending for the peer', () async {
      final result = await ChatService.processPendingForPeer(
        userId: userId,
        peerId: peerId,
        keyManager: keyManager,
      );
      expect(result, isFalse);
    });

    test('reports work done and leaves undelivered messages queued',
        () async {
      await DBHelper.insertOrUpdateUser({
        'id': peerId,
        'name': 'Peer',
        'identityJson': peerIdentityJson,
        'publicKeyPem': peerIdentityJson,
      });
      await MessagesDb.insertMessage({
        'id': 'msg-1',
        'senderId': userId,
        'receiverId': peerId,
        'message': 'self-cipher',
        'type': 'text',
        'status': 'pending',
        'timestamp': 1,
      });
      await PendingMessageDbHelper.insertPendingMessage({
        'id': 'msg-1',
        'senderId': userId,
        'receiverId': peerId,
        'message': 'peer-cipher',
        'type': 'text',
        'timestamp': 1,
        'status': 'pending',
      });

      final result = await ChatService.processPendingForPeer(
        userId: userId,
        peerId: peerId,
        keyManager: keyManager,
      );

      expect(result, isTrue);
      final remaining = await PendingMessageDbHelper.getPendingMessages(
        receiverId: peerId,
      );
      expect(remaining, hasLength(1));
    });
  });

  group('processGlobalPending', () {
    test('returns false when there are no pending direct messages',
        () async {
      final result = await ChatService.processGlobalPending(
        userId: userId,
        keyManager: keyManager,
      );
      expect(result, isFalse);
    });

    test('reports work done and leaves undelivered messages queued',
        () async {
      await DBHelper.insertOrUpdateUser({
        'id': peerId,
        'name': 'Peer',
        'identityJson': peerIdentityJson,
        'publicKeyPem': peerIdentityJson,
      });
      await MessagesDb.insertMessage({
        'id': 'msg-1',
        'senderId': userId,
        'receiverId': peerId,
        'message': 'self-cipher',
        'type': 'text',
        'status': 'pending',
        'timestamp': 1,
      });
      await PendingMessageDbHelper.insertPendingMessage({
        'id': 'msg-1',
        'senderId': userId,
        'receiverId': peerId,
        'message': 'peer-cipher',
        'type': 'text',
        'timestamp': 1,
        'status': 'pending',
      });

      final result = await ChatService.processGlobalPending(
        userId: userId,
        keyManager: keyManager,
      );

      expect(result, isTrue);
      final remaining = await PendingMessageDbHelper.getPendingMessages(
        receiverId: peerId,
      );
      expect(remaining, hasLength(1));
    });
  });

  group('SideChannelPostman injection (Fase 3.3)', () {
    test('sendTextMessage delivers through the injected postman', () async {
      TorRuntimeGate.resetForTest();
      final postman = _FakePostman();
      final service = ChatService(
        userId: userId,
        peerId: peerId,
        keyManager: keyManager,
        postman: postman,
      );
      addTearDown(service.dispose);
      service.peerIdentity = IdentityPublicKeys(
        signPublic: await peerKeyPair.signPublicKey,
        agreePublic: await peerKeyPair.agreePublicKey,
        fingerprint: 'test',
      );

      final id = await service.sendTextMessage('hello');

      expect(postman.directCalls, hasLength(1));
      final call = postman.directCalls.single;
      expect(call.peerId, peerId);
      expect(call.payload['id'], id);
      expect(call.payload['type'], 'text');
      expect(call.timeout, const Duration(seconds: 30));

      final stored = await MessagesDb.getMessageById(id!);
      expect(stored.first['status'], 'sent');
      expect(await PendingMessageDbHelper.getPendingMessages(receiverId: peerId),
          isEmpty);
    });

    test(
      'retrying a queued large-media message uses a 5 minute timeout',
      () async {
        TorRuntimeGate.resetForTest();
        final postman = _FakePostman();
        final service = ChatService(
          userId: userId,
          peerId: peerId,
          keyManager: keyManager,
          postman: postman,
        );
        addTearDown(service.dispose);
        service.peerIdentity = IdentityPublicKeys(
          signPublic: await peerKeyPair.signPublicKey,
          agreePublic: await peerKeyPair.agreePublicKey,
          fingerprint: 'test',
        );

        // Feed the retry path directly (already-encrypted payload sitting
        // in the pending queue), avoiding sendFileMessage's isolate-based
        // encryption — irrelevant to timeout selection, which _sendOverTor
        // derives purely from `type`.
        const id = 'img-1';
        await MessagesDb.insertMessage({
          'id': id,
          'senderId': userId,
          'receiverId': peerId,
          'message': 'self-cipher',
          'type': 'image',
          'status': 'pending',
          'timestamp': 1,
        }, notifyListeners: false);
        await PendingMessageDbHelper.insertPendingMessage({
          'id': id,
          'senderId': userId,
          'receiverId': peerId,
          'message': 'peer-cipher',
          'type': 'image',
          'timestamp': 1,
          'status': 'pending',
        });

        final sent = service.onMessageStatus.firstWhere(
          (u) => u.messageId == id && u.status == 'sent',
        );
        service.startSendQueue();
        await sent.timeout(const Duration(seconds: 5));
        // startSendQueue()'s send-queue loop is fire-and-forget; let its
        // trailing "any pending left?" check settle before the shared
        // tearDown() closes the databases out from under it.
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(postman.directCalls, hasLength(1));
        expect(postman.directCalls.single.payload['type'], 'image');
        expect(postman.directCalls.single.timeout, const Duration(minutes: 5));
      },
    );
  });
}
