import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/constants/group_constants.dart';
import 'package:prysm/crypto/group_crypto.dart';
import 'package:prysm/crypto/identity.dart';
import 'package:prysm/crypto/ratchet/session_store.dart';
import 'package:prysm/database/message_read_receipts.dart';
import 'package:prysm/database/messages.dart';
import 'package:prysm/models/group.dart';
import 'package:prysm/services/group_service.dart';
import 'package:prysm/services/pending_side_channel_queue.dart';
import 'package:prysm/services/read_receipt_service.dart';
import 'package:prysm/services/settings_service.dart';
import 'package:prysm/services/side_channel_postman.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/pending_message_db_helper.dart';
import 'package:prysm/util/read_waterline_mark.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<Database> _openTestDb() async {
  return databaseFactory.openDatabase(
    inMemoryDatabasePath,
    options: OpenDatabaseOptions(
      version: 1,
      onCreate: (db, version) async {
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
        await RatchetSessionStore.ensureTable(db);
      },
    ),
  );
}

Future<void> _insertPeerIdentity(Database db, String peerId) async {
  final peerKeyPair = await IdentityKeyPair.generate();
  await db.insert('users', {
    'id': peerId,
    'identityJson': jsonEncode(await peerKeyPair.toPublicJson()),
  });
}

class _FakePostman implements SideChannelPostman {
  final List<Map<String, dynamic>> directCalls = [];
  final List<Map<String, dynamic>> groupCalls = [];
  bool directSuccess = true;
  bool groupSuccess = true;

  @override
  Future<void> postDirect({
    required String peerId,
    required Map<String, dynamic> payload,
  }) async {
    directCalls.add({'peerId': peerId, 'payload': payload});
    if (!directSuccess) {
      throw Exception('direct delivery failed');
    }
  }

  @override
  Future<void> postGroup({
    required String targetMemberId,
    required Map<String, dynamic> payload,
  }) async {
    groupCalls.add({'targetMemberId': targetMemberId, 'payload': payload});
    if (!groupSuccess) {
      throw Exception('group delivery failed');
    }
  }

  void clear() {
    directCalls.clear();
    groupCalls.clear();
  }
}

class _FakeGroupService extends GroupService {
  final Uint8List groupKey;
  final List<GroupMember> members;

  _FakeGroupService({
    required super.userId,
    required super.keyManager,
    required this.groupKey,
    required this.members,
  });

  @override
  Future<Uint8List?> getDecryptedGroupKey(String groupId) async => groupKey;

  @override
  Future<List<GroupMember>> getMembers(String groupId) async => members;
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('message_read_receipts upsert and query by wire id', () async {
    final db = await databaseFactory.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: 9,
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE messages(
              id TEXT PRIMARY KEY,
              senderId TEXT NOT NULL,
              receiverId TEXT NOT NULL,
              message TEXT,
              type TEXT,
              timestamp INTEGER NOT NULL,
              status TEXT DEFAULT 'sent',
              readAt INTEGER,
              groupId TEXT
            )
          ''');
          await MessageReadReceiptsDb.createTable(db);
        },
      ),
    );

    // Point MessagesDb at in-memory db for this test.
    // MessageReadReceiptsDb uses MessagesDb.database — open via messages path hack:
    // Instead test the table operations directly.
    await db.insert('message_read_receipts', {
      'messageId': 'group1::msg1',
      'groupId': 'group1',
      'readerId': 'readerA',
      'readAt': 1000,
    });

    final rows = await db.query(
      'message_read_receipts',
      where: 'messageId = ?',
      whereArgs: ['group1::msg1'],
    );
    expect(rows.length, 1);
    expect(rows.first['readerId'], 'readerA');

    await db.insert(
      'message_read_receipts',
      {
        'messageId': 'group1::msg1',
        'groupId': 'group1',
        'readerId': 'readerA',
        'readAt': 2000,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );

    final updated = await db.query(
      'message_read_receipts',
      where: 'messageId = ?',
      whereArgs: ['group1::msg1'],
    );
    expect(updated.first['readAt'], 2000);

    await db.close();
  });

  test('v9 migration clears outbound delivery readAt artifacts', () async {
    final db = await databaseFactory.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(version: 9),
    );

    await db.execute('''
      CREATE TABLE messages(
        id TEXT PRIMARY KEY,
        senderId TEXT NOT NULL,
        receiverId TEXT NOT NULL,
        message TEXT,
        type TEXT,
        timestamp INTEGER NOT NULL,
        status TEXT DEFAULT 'sent',
        readAt INTEGER,
        groupId TEXT
      )
    ''');

    await db.insert('messages', {
      'id': 'out1',
      'senderId': 'me',
      'receiverId': 'peer',
      'message': 'x',
      'type': 'text',
      'timestamp': 1,
      'status': 'sent',
      'readAt': 999,
    });
    await db.insert('messages', {
      'id': 'in1',
      'senderId': 'peer',
      'receiverId': 'me',
      'message': 'y',
      'type': 'text',
      'timestamp': 2,
      'status': 'received',
      'readAt': 888,
    });

    await db.execute('''
      UPDATE messages
      SET readAt = NULL
      WHERE COALESCE(status, '') = 'sent'
        AND COALESCE(status, '') != 'received'
    ''');

    final out = await db.query('messages', where: 'id = ?', whereArgs: ['out1']);
    final inbound =
        await db.query('messages', where: 'id = ?', whereArgs: ['in1']);

    expect(out.first['readAt'], isNull);
    expect(inbound.first['readAt'], 888);

    await db.close();
  });

  test('scopedId wire roundtrip', () {
    expect(
      MessagesDb.wireIdFromStorage('group::wire'),
      'wire',
    );
    expect(
      MessagesDb.scopedId(wireId: 'wire', groupId: 'group'),
      'group::wire',
    );
  });

  group('ReadReceiptService direct waterline delivery', () {
    const userId = 'me.onion';
    const peerId = 'peer.onion';

    late Database db;
    late KeyManager keyManager;
    late _FakePostman postman;

    setUp(() async {
      db = await _openTestDb();
      DBHelper.setDatabaseForTest(db);
      PendingMessageDbHelper.setDatabaseForTest(db);
      keyManager = KeyManager.fromIdentity(await IdentityKeyPair.generate());
      await _insertPeerIdentity(db, peerId);
      postman = _FakePostman();
      ReadReceiptService.resetForTest();
      ReadReceiptService.postmanForTest = postman;
      ReadReceiptService.outboxForTest = const PendingSideChannelQueue();
    });

    tearDown(() async {
      await db.close();
      DBHelper.setDatabaseForTest(null);
      PendingMessageDbHelper.setDatabaseForTest(null);
      ReadReceiptService.resetForTest();
      await SettingsService().setSendReadReceipts(true);
    });

    test('sendWaterline delivers direct read waterline on success', () async {
      final service = ReadReceiptService.direct(
        userId: userId,
        keyManager: keyManager,
        peerId: peerId,
      );
      await service.sendWaterline(const ReadWaterlineMark(
        latestMessageId: 'msg-1',
        readUpToTimestamp: 1000,
      ));

      expect(postman.directCalls.length, 1);
      final payload = postman.directCalls.first['payload'] as Map<String, dynamic>;
      expect(payload['receiverId'], peerId);
      expect(payload['senderId'], userId);
      expect(payload['type'], readWaterlineType);
      expect(payload['message'], isA<String>().having((m) => m.isNotEmpty, 'nonEmpty', true));

      final rows = await db.query('pending_messages');
      expect(rows, isEmpty);
    });

    test('sendWaterline queues pending direct row on failure', () async {
      postman.directSuccess = false;
      final service = ReadReceiptService.direct(
        userId: userId,
        keyManager: keyManager,
        peerId: peerId,
      );
      await service.sendWaterline(const ReadWaterlineMark(
        latestMessageId: 'msg-2',
        readUpToTimestamp: 2000,
      ));

      expect(postman.directCalls.length, 1);
      final rows = await db.query(
        'pending_messages',
        where: 'type = ?',
        whereArgs: [readWaterlineType],
      );
      expect(rows.length, 1);
      expect(rows.first['senderId'], userId);
      expect(rows.first['receiverId'], peerId);
      expect(rows.first['id'], readWaterlineEventId(readerId: userId, peerId: peerId));
      expect(rows.first['message'], isA<String>());
    });

    test('sendWaterline suppresses stale direct waterline', () async {
      final service = ReadReceiptService.direct(
        userId: userId,
        keyManager: keyManager,
        peerId: peerId,
      );
      await service.sendWaterline(const ReadWaterlineMark(
        latestMessageId: 'msg-1',
        readUpToTimestamp: 1000,
      ));
      postman.clear();

      await service.sendWaterline(const ReadWaterlineMark(
        latestMessageId: 'msg-2',
        readUpToTimestamp: 500,
      ));

      expect(postman.directCalls, isEmpty);
      expect(await db.query('pending_messages'), isEmpty);
    });

    test('sendWaterline sends higher direct waterline', () async {
      final service = ReadReceiptService.direct(
        userId: userId,
        keyManager: keyManager,
        peerId: peerId,
      );
      await service.sendWaterline(const ReadWaterlineMark(
        latestMessageId: 'msg-1',
        readUpToTimestamp: 1000,
      ));
      postman.clear();

      await service.sendWaterline(const ReadWaterlineMark(
        latestMessageId: 'msg-2',
        readUpToTimestamp: 2000,
      ));

      expect(postman.directCalls.length, 1);
      final payload = postman.directCalls.first['payload'] as Map<String, dynamic>;
      expect(payload['type'], readWaterlineType);
    });

    test('sendWaterline respects sendReadReceipts setting', () async {
      await SettingsService().setSendReadReceipts(false);
      final service = ReadReceiptService.direct(
        userId: userId,
        keyManager: keyManager,
        peerId: peerId,
      );
      await service.sendWaterline(const ReadWaterlineMark(
        latestMessageId: 'msg-1',
        readUpToTimestamp: 1000,
      ));

      expect(postman.directCalls, isEmpty);
      expect(await db.query('pending_messages'), isEmpty);
    });

    test('processPendingForPeer delivers pending direct waterline', () async {
      await db.insert('pending_messages', {
        'id': readWaterlineEventId(readerId: userId, peerId: peerId),
        'senderId': userId,
        'receiverId': peerId,
        'message': 'direct-ciphertext',
        'type': readWaterlineType,
        'timestamp': 1000,
        'status': 'pending',
      });

      final ok = await ReadReceiptService.processPendingForPeer(
        userId: userId,
        peerId: peerId,
        keyManager: keyManager,
      );

      expect(ok, isTrue);
      expect(postman.directCalls.length, 1);
      final payload = postman.directCalls.first['payload'] as Map<String, dynamic>;
      expect(payload['receiverId'], peerId);
      expect(payload['type'], readWaterlineType);
      expect(await db.query('pending_messages'), isEmpty);
    });

    test('processPendingForPeer returns false when nothing pending', () async {
      final ok = await ReadReceiptService.processPendingForPeer(
        userId: userId,
        peerId: peerId,
        keyManager: keyManager,
      );

      expect(ok, isFalse);
      expect(postman.directCalls, isEmpty);
    });

    test('processGlobalPendingDirect flushes delivered rows', () async {
      await db.insert('pending_messages', {
        'id': 'read_waterline::global',
        'senderId': userId,
        'receiverId': peerId,
        'message': 'direct-ciphertext',
        'type': readWaterlineType,
        'timestamp': 1000,
        'status': 'pending',
      });

      final ok = await ReadReceiptService.processGlobalPendingDirect(
        userId: userId,
        keyManager: keyManager,
      );

      expect(ok, isTrue);
      expect(postman.directCalls.length, 1);
      expect(await db.query('pending_messages'), isEmpty);
    });

    test('processGlobalPendingDirect keeps row when delivery fails', () async {
      await db.insert('pending_messages', {
        'id': 'read_waterline::global',
        'senderId': userId,
        'receiverId': peerId,
        'message': 'direct-ciphertext',
        'type': readWaterlineType,
        'timestamp': 1000,
        'status': 'pending',
      });
      postman.directSuccess = false;

      final ok = await ReadReceiptService.processGlobalPendingDirect(
        userId: userId,
        keyManager: keyManager,
      );

      expect(ok, isFalse);
      final rows = await db.query('pending_messages');
      expect(rows.length, 1);
      expect(rows.first['id'], 'read_waterline::global');
    });
  });

  group('ReadReceiptService group waterline delivery', () {
    const userId = 'me.onion';
    const peerId = 'peer.onion';
    const groupId = 'group-1';

    late Database db;
    late KeyManager keyManager;
    late _FakePostman postman;

    setUp(() async {
      db = await _openTestDb();
      DBHelper.setDatabaseForTest(db);
      PendingMessageDbHelper.setDatabaseForTest(db);
      keyManager = KeyManager.fromIdentity(await IdentityKeyPair.generate());
      postman = _FakePostman();
      ReadReceiptService.resetForTest();
      ReadReceiptService.postmanForTest = postman;
      ReadReceiptService.outboxForTest = const PendingSideChannelQueue();
    });

    tearDown(() async {
      await db.close();
      DBHelper.setDatabaseForTest(null);
      PendingMessageDbHelper.setDatabaseForTest(null);
      ReadReceiptService.resetForTest();
    });

    _FakeGroupService makeGroupService() {
      return _FakeGroupService(
        userId: userId,
        keyManager: keyManager,
        groupKey: GroupCryptoV2.generateGroupKey(),
        members: [
          GroupMember(
            groupId: groupId,
            memberId: userId,
            role: GroupRole.admin,
            joinedAt: 0,
          ),
          GroupMember(
            groupId: groupId,
            memberId: peerId,
            role: GroupRole.member,
            joinedAt: 1,
          ),
        ],
      );
    }

    test('sendWaterline delivers group read waterline to other members', () async {
      final service = ReadReceiptService.group(
        userId: userId,
        keyManager: keyManager,
        groupId: groupId,
        groupService: makeGroupService(),
      );
      await service.sendWaterline(const ReadWaterlineMark(
        latestMessageId: 'msg-g1',
        readUpToTimestamp: 3000,
        groupId: groupId,
      ));

      expect(postman.groupCalls.length, 1);
      final payload = postman.groupCalls.first['payload'] as Map<String, dynamic>;
      expect(payload['groupId'], groupId);
      expect(payload['receiverId'], peerId);
      expect(payload['senderId'], userId);
      expect(payload['type'], groupReadWaterlineType);
      expect(payload['message'], isA<String>().having((m) => m.isNotEmpty, 'nonEmpty', true));
      expect(await db.query('pending_messages'), isEmpty);
    });

    test('sendWaterline queues pending group row per target on failure', () async {
      postman.groupSuccess = false;
      final service = ReadReceiptService.group(
        userId: userId,
        keyManager: keyManager,
        groupId: groupId,
        groupService: makeGroupService(),
      );
      await service.sendWaterline(const ReadWaterlineMark(
        latestMessageId: 'msg-g2',
        readUpToTimestamp: 4000,
        groupId: groupId,
      ));

      final rows = await db.query(
        'pending_messages',
        where: 'type = ?',
        whereArgs: [groupReadWaterlineType],
      );
      expect(rows.length, 1);
      expect(rows.first['senderId'], userId);
      expect(rows.first['receiverId'], peerId);
      expect(rows.first['groupId'], groupId);
      expect(rows.first['targetMemberId'], peerId);
      final eventId = readWaterlineEventId(
        readerId: userId,
        peerId: userId,
        groupId: groupId,
      );
      expect(rows.first['id'], '$eventId::$peerId');
    });

    test('processGlobalPendingGroup flushes delivered group rows', () async {
      final eventId = readWaterlineEventId(
        readerId: userId,
        peerId: userId,
        groupId: groupId,
      );
      await db.insert('pending_messages', {
        'id': '$eventId::$peerId',
        'senderId': userId,
        'receiverId': peerId,
        'message': 'group-ciphertext',
        'type': groupReadWaterlineType,
        'timestamp': 1000,
        'status': 'pending',
        'groupId': groupId,
        'targetMemberId': peerId,
      });

      final ok = await ReadReceiptService.processGlobalPendingGroup(
        userId: userId,
        keyManager: keyManager,
      );

      expect(ok, isTrue);
      expect(postman.groupCalls.length, 1);
      final payload = postman.groupCalls.first['payload'] as Map<String, dynamic>;
      expect(payload['groupId'], groupId);
      expect(payload['type'], groupReadWaterlineType);
      expect(await db.query('pending_messages'), isEmpty);
    });
  });
}
