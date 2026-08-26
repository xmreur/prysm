import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/database/message_schema_migrations.dart';
import 'package:prysm/database/messages.dart';
import 'package:prysm/services/pending_queue_reconciler.dart';
import 'package:prysm/util/pending_message_db_helper.dart';
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
      targetMemberId TEXT,
      forwarded INTEGER DEFAULT 0
    )
  ''');
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
      editedAt INTEGER,
      expiresAt INTEGER,
      forwarded INTEGER NOT NULL DEFAULT 0
    )
  ''');
  await MessageSchemaMigrations.createMessageSearchFtsTable(db);
  return db;
}

void main() {
  const userId = 'me.onion';
  const peerId = 'peer.onion';

  late Directory docsDir;
  late Database pendingDb;
  late Database messagesDb;

  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;

    // MessagesDb.getMessageById unconditionally probes MessageBlobStore,
    // which shells out to path_provider even for small inline payloads.
    docsDir = Directory.systemTemp.createTempSync('pending_reconciler_test');
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

  setUp(() async {
    pendingDb = await _openPendingDb();
    PendingMessageDbHelper.setDatabaseForTest(pendingDb);

    messagesDb = await _openMessagesDb();
    MessagesDb.setDatabaseForTest(messagesDb);
  });

  tearDown(() async {
    await pendingDb.close();
    PendingMessageDbHelper.setDatabaseForTest(null);

    await messagesDb.close();
    MessagesDb.setDatabaseForTest(null);
  });

  PendingQueueReconciler buildReconciler({
    required List<String> requeued,
    required Future<bool> Function(Map<String, dynamic>) sendPending,
    required List<String> markedSent,
    bool hasIdentity = true,
    bool disposed = false,
    Set<String> inFlight = const {},
  }) {
    return PendingQueueReconciler(
      userId: userId,
      peerId: peerId,
      isDisposed: () => disposed,
      hasPeerIdentity: () => hasIdentity,
      isInFlight: inFlight.contains,
      requeue: (wireId) async => requeued.add(wireId),
      sendPending: sendPending,
      markAsSent: (id) async => markedSent.add(id),
    );
  }

  group('reconcile', () {
    test('requeues a message row missing from the pending table', () async {
      await MessagesDb.insertMessage({
        'id': 'msg-1',
        'senderId': userId,
        'receiverId': peerId,
        'message': 'self-cipher',
        'type': 'text',
        'status': 'pending',
        'timestamp': 1,
      });

      final requeued = <String>[];
      final reconciler = buildReconciler(
        requeued: requeued,
        sendPending: (_) async => false,
        markedSent: [],
      );

      await reconciler.reconcile();

      expect(requeued, ['msg-1']);
    });

    test('does not requeue a row already present in the pending table', () async {
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

      final requeued = <String>[];
      final reconciler = buildReconciler(
        requeued: requeued,
        sendPending: (_) async => false,
        markedSent: [],
      );

      await reconciler.reconcile();

      expect(requeued, isEmpty);
    });

    test('does nothing without a resolved peer identity', () async {
      await MessagesDb.insertMessage({
        'id': 'msg-1',
        'senderId': userId,
        'receiverId': peerId,
        'message': 'self-cipher',
        'type': 'text',
        'status': 'pending',
        'timestamp': 1,
      });

      final requeued = <String>[];
      final reconciler = buildReconciler(
        requeued: requeued,
        sendPending: (_) async => false,
        markedSent: [],
        hasIdentity: false,
      );

      await reconciler.reconcile();

      expect(requeued, isEmpty);
    });
  });

  group('flushOnce', () {
    test('delivers a queued row and removes it on success', () async {
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
        'forwarded': 1,
      });

      Map<String, dynamic>? sentRow;
      final markedSent = <String>[];
      final reconciler = buildReconciler(
        requeued: [],
        sendPending: (row) async {
          sentRow = row;
          return true;
        },
        markedSent: markedSent,
      );

      await reconciler.flushOnce();

      expect(markedSent, ['msg-1']);
      expect(sentRow?['forwarded'], 1);
      final remaining = await PendingMessageDbHelper.getPendingMessages(
        receiverId: peerId,
      );
      expect(remaining, isEmpty);
    });

    test('stops at the first failure and leaves later rows queued', () async {
      for (final id in ['msg-1', 'msg-2']) {
        await MessagesDb.insertMessage({
          'id': id,
          'senderId': userId,
          'receiverId': peerId,
          'message': 'self-cipher',
          'type': 'text',
          'status': 'pending',
          'timestamp': 1,
        });
        await PendingMessageDbHelper.insertPendingMessage({
          'id': id,
          'senderId': userId,
          'receiverId': peerId,
          'message': 'peer-cipher',
          'type': 'text',
          'timestamp': 1,
          'status': 'pending',
        });
      }

      final attempts = <String>[];
      final reconciler = buildReconciler(
        requeued: [],
        sendPending: (row) async {
          attempts.add(row['id'] as String);
          return false;
        },
        markedSent: [],
      );

      await reconciler.flushOnce();

      expect(attempts, ['msg-1']);
      final remaining = await PendingMessageDbHelper.getPendingMessages(
        receiverId: peerId,
      );
      expect(remaining, hasLength(2));
    });

    test('drops a pending row whose message was deleted, without sending', () async {
      await MessagesDb.insertMessage({
        'id': 'msg-1',
        'senderId': userId,
        'receiverId': peerId,
        'message': 'self-cipher',
        'type': 'text',
        'status': 'pending',
        'timestamp': 1,
      });
      await MessagesDb.deleteMessageById('msg-1');
      await PendingMessageDbHelper.insertPendingMessage({
        'id': 'msg-1',
        'senderId': userId,
        'receiverId': peerId,
        'message': 'peer-cipher',
        'type': 'text',
        'timestamp': 1,
        'status': 'pending',
      });

      var sendCalled = false;
      final reconciler = buildReconciler(
        requeued: [],
        sendPending: (_) async {
          sendCalled = true;
          return true;
        },
        markedSent: [],
      );

      await reconciler.flushOnce();

      expect(sendCalled, isFalse);
      final remaining = await PendingMessageDbHelper.getPendingMessages(
        receiverId: peerId,
      );
      expect(remaining, isEmpty);
    });

    test('does nothing without a resolved peer identity', () async {
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

      var sendCalled = false;
      final reconciler = buildReconciler(
        requeued: [],
        sendPending: (_) async {
          sendCalled = true;
          return true;
        },
        markedSent: [],
        hasIdentity: false,
      );

      await reconciler.flushOnce();

      expect(sendCalled, isFalse);
    });
  });

  group('static helpers', () {
    test('chatPendingForReceiver excludes side-channel pending types', () async {
      await PendingMessageDbHelper.insertPendingMessage({
        'id': 'msg-1',
        'senderId': userId,
        'receiverId': peerId,
        'message': 'peer-cipher',
        'type': 'text',
        'timestamp': 1,
        'status': 'pending',
      });
      await PendingMessageDbHelper.insertPendingMessage({
        'id': 'reaction-1',
        'senderId': userId,
        'receiverId': peerId,
        'message': 'peer-cipher',
        'type': 'reaction',
        'timestamp': 2,
        'status': 'pending',
      });

      final chatPending = await PendingQueueReconciler.chatPendingForReceiver(
        senderId: userId,
        receiverId: peerId,
      );

      expect(chatPending.map((m) => m['id']), ['msg-1']);
    });

    test('peersWithPendingDirectMessages is unfiltered by type', () async {
      await PendingMessageDbHelper.insertPendingMessage({
        'id': 'reaction-1',
        'senderId': userId,
        'receiverId': peerId,
        'message': 'peer-cipher',
        'type': 'reaction',
        'timestamp': 1,
        'status': 'pending',
      });

      final peers = await PendingQueueReconciler.peersWithPendingDirectMessages(
        senderId: userId,
      );

      expect(peers, {peerId});
    });
  });
}
