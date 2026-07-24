import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/services/pending_side_channel_queue.dart';
import 'package:prysm/services/side_channel_postman.dart';
import 'package:prysm/services/side_channel_transport.dart';
import 'package:prysm/util/pending_message_db_helper.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<Database> _openPendingTestDb() async {
  return databaseFactory.openDatabase(
    inMemoryDatabasePath,
    options: OpenDatabaseOptions(
      version: 4,
      onCreate: (db, version) async {
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
        await db.execute(
          'CREATE INDEX idx_pending_receiver ON pending_messages(receiverId)',
        );
        await db.execute(
          'CREATE INDEX idx_pending_timestamp ON pending_messages(timestamp)',
        );
      },
    ),
  );
}

class _Post {
  final String target;
  final Map<String, dynamic> payload;

  _Post(this.target, this.payload);
}

class _FakePostman implements SideChannelPostman {
  final List<_Post> direct = [];
  final List<_Post> group = [];
  int failNext = 0;

  void reset() {
    direct.clear();
    group.clear();
    failNext = 0;
  }

  @override
  Future<void> postDirect({
    required String peerId,
    required Map<String, dynamic> payload,
  }) async {
    direct.add(_Post(peerId, payload));
    if (failNext > 0) {
      failNext--;
      throw Exception('connection refused');
    }
  }

  @override
  Future<void> postGroup({
    required String targetMemberId,
    required Map<String, dynamic> payload,
  }) async {
    group.add(_Post(targetMemberId, payload));
    if (failNext > 0) {
      failNext--;
      throw Exception('connection refused');
    }
  }
}

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  tearDown(() {
    PendingMessageDbHelper.setDatabaseForTest(null);
  });

  group('SideChannelTransport direct delivery', () {
    late Database db;
    late _FakePostman postman;
    late SideChannelTransport transport;

    setUp(() async {
      db = await _openPendingTestDb();
      PendingMessageDbHelper.setDatabaseForTest(db);
      postman = _FakePostman();
      transport = SideChannelTransport(
        userId: 'me.onion',
        outbox: const PendingSideChannelQueue(),
        postman: postman,
        maxAttempts: 3,
      );
    });

    tearDown(() async {
      await db.close();
    });

    test('sendDirect delivers payload and returns true', () async {
      final ok = await transport.sendDirect(
        id: 'r-1',
        peerId: 'peer.onion',
        encrypted: 'ciphertext',
        timestamp: 1000,
        type: 'reaction',
      );

      expect(ok, isTrue);
      expect(postman.direct.length, 1);
      final post = postman.direct.first;
      expect(post.target, 'peer.onion');
      expect(post.payload['id'], 'r-1');
      expect(post.payload['senderId'], 'me.onion');
      expect(post.payload['receiverId'], 'peer.onion');
      expect(post.payload['message'], 'ciphertext');
      expect(post.payload['type'], 'reaction');
      expect(post.payload['timestamp'], 1000);
    });

    test('sendDirect retries transient failures then succeeds', () async {
      postman.failNext = 2;

      final ok = await transport.sendDirect(
        id: 'r-1',
        peerId: 'peer.onion',
        encrypted: 'ciphertext',
        timestamp: 1000,
        type: 'reaction',
      );

      expect(ok, isTrue);
      expect(postman.direct.length, 3);
    });

    test('sendDirect fast-fail does not retry', () async {
      postman.failNext = 2;

      final ok = await transport.sendDirect(
        id: 'r-1',
        peerId: 'peer.onion',
        encrypted: 'ciphertext',
        timestamp: 1000,
        type: 'reaction',
        fastFail: true,
      );

      expect(ok, isFalse);
      expect(postman.direct.length, 1);
    });

    test('sendDirectAndQueue queues on failure', () async {
      postman.failNext = 3;

      final ok = await transport.sendDirectAndQueue(
        id: 'r-1',
        peerId: 'peer.onion',
        encrypted: 'ciphertext',
        timestamp: 1000,
        type: 'reaction',
      );

      expect(ok, isFalse);
      expect(postman.direct.length, 3);
      final pending = await transport.outbox.getPendingDirect(
        senderId: 'me.onion',
        types: {'reaction'},
      );
      expect(pending.length, 1);
      expect(pending.first.id, 'r-1');
    });

    test('flushPendingForPeer delivers and removes pending rows', () async {
      await transport.outbox.insertDirect(
        id: 'r-1',
        senderId: 'me.onion',
        receiverId: 'peer.onion',
        message: 'ciphertext',
        type: 'reaction',
        timestamp: 1000,
      );

      final flushed = await transport.flushPendingForPeer(
        peerId: 'peer.onion',
        types: {'reaction'},
      );

      expect(flushed, isTrue);
      expect(postman.direct.length, 1);
      final pending = await transport.outbox.getPendingDirect(
        senderId: 'me.onion',
        types: {'reaction'},
      );
      expect(pending, isEmpty);
    });

    test('flushPendingForPeer skips rows of other types', () async {
      await transport.outbox.insertDirect(
        id: 'r-1',
        senderId: 'me.onion',
        receiverId: 'peer.onion',
        message: 'ciphertext',
        type: 'reaction',
        timestamp: 1000,
      );

      final flushed = await transport.flushPendingForPeer(
        peerId: 'peer.onion',
        types: {'message_modify'},
      );

      expect(flushed, isFalse);
      expect(postman.direct, isEmpty);
    });

    test('flushGlobalPendingDirect delivers rows for all peers', () async {
      await transport.outbox.insertDirect(
        id: 'r-1',
        senderId: 'me.onion',
        receiverId: 'peer-a.onion',
        message: 'ciphertext-a',
        type: 'reaction',
        timestamp: 1000,
      );
      await transport.outbox.insertDirect(
        id: 'r-2',
        senderId: 'me.onion',
        receiverId: 'peer-b.onion',
        message: 'ciphertext-b',
        type: 'reaction',
        timestamp: 1001,
      );

      final flushed = await transport.flushGlobalPendingDirect(
        types: {'reaction'},
      );

      expect(flushed, isTrue);
      expect(postman.direct.length, 2);
      final targets = postman.direct.map((p) => p.target).toSet();
      expect(targets, {'peer-a.onion', 'peer-b.onion'});
      final pending = await transport.outbox.getPendingDirect(
        senderId: 'me.onion',
        types: {'reaction'},
      );
      expect(pending, isEmpty);
    });
  });

  group('SideChannelTransport group delivery', () {
    late Database db;
    late _FakePostman postman;
    late SideChannelTransport transport;

    setUp(() async {
      db = await _openPendingTestDb();
      PendingMessageDbHelper.setDatabaseForTest(db);
      postman = _FakePostman();
      transport = SideChannelTransport(
        userId: 'me.onion',
        outbox: const PendingSideChannelQueue(),
        postman: postman,
        maxAttempts: 3,
      );
    });

    tearDown(() async {
      await db.close();
    });

    test('sendGroup delivers payload and returns true', () async {
      final ok = await transport.sendGroup(
        id: 'gr-1',
        groupId: 'group-1',
        targetMemberId: 'member.onion',
        encrypted: 'ciphertext',
        timestamp: 1000,
        type: 'group_reaction',
      );

      expect(ok, isTrue);
      expect(postman.group.length, 1);
      final post = postman.group.first;
      expect(post.target, 'member.onion');
      expect(post.payload['id'], 'gr-1');
      expect(post.payload['senderId'], 'me.onion');
      expect(post.payload['receiverId'], 'member.onion');
      expect(post.payload['groupId'], 'group-1');
      expect(post.payload['message'], 'ciphertext');
      expect(post.payload['type'], 'group_reaction');
    });

    test('sendGroupAndQueue queues on failure', () async {
      postman.failNext = 3;

      final ok = await transport.sendGroupAndQueue(
        id: 'gr-1',
        groupId: 'group-1',
        targetMemberId: 'member.onion',
        encrypted: 'ciphertext',
        timestamp: 1000,
        type: 'group_reaction',
      );

      expect(ok, isFalse);
      expect(postman.group.length, 3);
      final pending = await transport.outbox.getPendingGroup(
        senderId: 'me.onion',
        types: {'group_reaction'},
      );
      expect(pending.length, 1);
      expect(pending.first.groupId, 'group-1');
      expect(pending.first.targetMemberId, 'member.onion');
    });

    test('flushGlobalPendingGroup delivers and removes pending rows', () async {
      await transport.outbox.insertGroup(
        id: 'gr-1__member.onion',
        senderId: 'me.onion',
        receiverId: 'member.onion',
        message: 'ciphertext',
        type: 'group_reaction',
        timestamp: 1000,
        groupId: 'group-1',
        targetMemberId: 'member.onion',
      );

      final flushed = await transport.flushGlobalPendingGroup(
        types: {'group_reaction'},
      );

      expect(flushed, isTrue);
      expect(postman.group.length, 1);
      // Default wireIdOf leaves the pending row id untouched on the wire.
      expect(postman.group.first.payload['id'], 'gr-1__member.onion');
      final pending = await transport.outbox.getPendingGroup(
        senderId: 'me.onion',
        types: {'group_reaction'},
      );
      expect(pending, isEmpty);
    });

    test('flushGlobalPendingGroup maps wire id via wireIdOf hook', () async {
      await transport.outbox.insertGroup(
        id: 'gr-1__member.onion',
        senderId: 'me.onion',
        receiverId: 'member.onion',
        message: 'ciphertext',
        type: 'group_reaction',
        timestamp: 1000,
        groupId: 'group-1',
        targetMemberId: 'member.onion',
      );

      final flushed = await transport.flushGlobalPendingGroup(
        types: {'group_reaction'},
        wireIdOf: (row) {
          final idx = row.id.lastIndexOf('__');
          return idx == -1 ? row.id : row.id.substring(0, idx);
        },
      );

      expect(flushed, isTrue);
      expect(postman.group.length, 1);
      expect(postman.group.first.payload['id'], 'gr-1');
      final pending = await transport.outbox.getPendingGroup(
        senderId: 'me.onion',
        types: {'group_reaction'},
      );
      expect(pending, isEmpty);
    });
  });
}
