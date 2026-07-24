import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/services/pending_side_channel_queue.dart';
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

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  tearDown(() {
    PendingMessageDbHelper.setDatabaseForTest(null);
  });

  group('PendingSideChannelQueue direct rows', () {
    late Database db;
    late PendingSideChannelQueue queue;

    setUp(() async {
      db = await _openPendingTestDb();
      PendingMessageDbHelper.setDatabaseForTest(db);
      queue = const PendingSideChannelQueue();
    });

    tearDown(() async {
      await db.close();
    });

    test('insertDirect stores a direct side-channel row', () async {
      await queue.insertDirect(
        id: 'r-1',
        senderId: 'me.onion',
        receiverId: 'peer.onion',
        message: 'ciphertext',
        type: 'reaction',
        timestamp: 1000,
      );

      final rows = await queue.getPendingDirect(
        senderId: 'me.onion',
        types: {'reaction'},
      );
      expect(rows.length, 1);
      expect(rows.first.id, 'r-1');
      expect(rows.first.receiverId, 'peer.onion');
      expect(rows.first.message, 'ciphertext');
    });

    test('getPendingDirect filters by type', () async {
      await queue.insertDirect(
        id: 'r-1',
        senderId: 'me.onion',
        receiverId: 'peer.onion',
        message: 'ciphertext',
        type: 'reaction',
        timestamp: 1000,
      );
      await queue.insertDirect(
        id: 'm-1',
        senderId: 'me.onion',
        receiverId: 'peer.onion',
        message: 'ciphertext',
        type: 'message_modify',
        timestamp: 1001,
      );

      final rows = await queue.getPendingDirect(
        senderId: 'me.onion',
        types: {'reaction'},
      );
      expect(rows.length, 1);
      expect(rows.first.type, 'reaction');
    });

    test('getPendingDirectForReceiver returns only that peer', () async {
      await queue.insertDirect(
        id: 'r-1',
        senderId: 'me.onion',
        receiverId: 'peer-a.onion',
        message: 'ciphertext',
        type: 'reaction',
        timestamp: 1000,
      );
      await queue.insertDirect(
        id: 'r-2',
        senderId: 'me.onion',
        receiverId: 'peer-b.onion',
        message: 'ciphertext',
        type: 'reaction',
        timestamp: 1001,
      );

      final rows = await queue.getPendingDirectForReceiver(
        senderId: 'me.onion',
        receiverId: 'peer-a.onion',
        types: {'reaction'},
      );
      expect(rows.length, 1);
      expect(rows.first.id, 'r-1');
    });

    test('remove deletes a single row', () async {
      await queue.insertDirect(
        id: 'r-1',
        senderId: 'me.onion',
        receiverId: 'peer.onion',
        message: 'ciphertext',
        type: 'reaction',
        timestamp: 1000,
      );

      await queue.remove('r-1');
      final rows = await queue.getPendingDirect(
        senderId: 'me.onion',
        types: {'reaction'},
      );
      expect(rows, isEmpty);
    });

    test('removeAll deletes multiple rows', () async {
      await queue.insertDirect(
        id: 'r-1',
        senderId: 'me.onion',
        receiverId: 'peer.onion',
        message: 'ciphertext',
        type: 'reaction',
        timestamp: 1000,
      );
      await queue.insertDirect(
        id: 'r-2',
        senderId: 'me.onion',
        receiverId: 'peer.onion',
        message: 'ciphertext',
        type: 'reaction',
        timestamp: 1001,
      );

      await queue.removeAll(['r-1', 'r-2']);
      final rows = await queue.getPendingDirect(
        senderId: 'me.onion',
        types: {'reaction'},
      );
      expect(rows, isEmpty);
    });
  });

  group('PendingSideChannelQueue group rows', () {
    late Database db;
    late PendingSideChannelQueue queue;

    setUp(() async {
      db = await _openPendingTestDb();
      PendingMessageDbHelper.setDatabaseForTest(db);
      queue = const PendingSideChannelQueue();
    });

    tearDown(() async {
      await db.close();
    });

    test('insertGroup stores a group side-channel row', () async {
      await queue.insertGroup(
        id: 'gr-1__member.onion',
        senderId: 'me.onion',
        receiverId: 'member.onion',
        message: 'ciphertext',
        type: 'group_reaction',
        timestamp: 1000,
        groupId: 'group-1',
        targetMemberId: 'member.onion',
      );

      final rows = await queue.getPendingGroup(
        senderId: 'me.onion',
        types: {'group_reaction'},
      );
      expect(rows.length, 1);
      expect(rows.first.groupId, 'group-1');
      expect(rows.first.targetMemberId, 'member.onion');
    });

    test('getPendingGroup filters by type', () async {
      await queue.insertGroup(
        id: 'gr-1',
        senderId: 'me.onion',
        receiverId: 'member.onion',
        message: 'ciphertext',
        type: 'group_reaction',
        timestamp: 1000,
        groupId: 'group-1',
        targetMemberId: 'member.onion',
      );
      await queue.insertGroup(
        id: 'gm-1',
        senderId: 'me.onion',
        receiverId: 'member.onion',
        message: 'ciphertext',
        type: 'group_message_modify',
        timestamp: 1001,
        groupId: 'group-1',
        targetMemberId: 'member.onion',
      );

      final rows = await queue.getPendingGroup(
        senderId: 'me.onion',
        types: {'group_message_modify'},
      );
      expect(rows.length, 1);
      expect(rows.first.type, 'group_message_modify');
    });
  });
}
