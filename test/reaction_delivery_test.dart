import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/constants/group_constants.dart';
import 'package:prysm/crypto/group_crypto.dart';
import 'package:prysm/crypto/identity.dart';
import 'package:prysm/crypto/ratchet/session_store.dart';
import 'package:prysm/models/group.dart';
import 'package:prysm/services/group_service.dart';
import 'package:prysm/services/pending_side_channel_queue.dart';
import 'package:prysm/services/reaction_service.dart';
import 'package:prysm/services/side_channel_postman.dart';
import 'package:prysm/database/message_reactions.dart';
import 'package:prysm/services/side_channel_transport.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/pending_message_db_helper.dart';
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
        await MessageReactionsDb.createTable(db);
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
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('ReactionService direct delivery', () {
    const userId = 'me.onion';
    const peerId = 'peer.onion';

    late Database db;
    late KeyManager keyManager;
    late _FakePostman postman;
    late SideChannelTransport transport;

    setUp(() async {
      db = await _openTestDb();
      DBHelper.setDatabaseForTest(db);
      PendingMessageDbHelper.setDatabaseForTest(db);
      MessageReactionsDb.debugDatabase = db;
      keyManager = KeyManager.fromIdentity(await IdentityKeyPair.generate());
      await _insertPeerIdentity(db, peerId);
      postman = _FakePostman();
      transport = SideChannelTransport(
        userId: userId,
        outbox: const PendingSideChannelQueue(),
        postman: postman,
        maxAttempts: 1,
      );
      ReactionService.resetForTest();
      ReactionService.configure(transport: transport);
    });

    tearDown(() async {
      await db.close();
      DBHelper.setDatabaseForTest(null);
      PendingMessageDbHelper.setDatabaseForTest(null);
      MessageReactionsDb.debugDatabase = null;
      ReactionService.resetForTest();
    });

    test('toggleReaction delivers direct reaction on success', () async {
      final service = ReactionService.direct(
        userId: userId,
        keyManager: keyManager,
        peerId: peerId,
      );
      await service.toggleReaction(targetMessageId: 'msg-1', emoji: '👍');

      expect(postman.directCalls.length, 1);
      final payload = postman.directCalls.first['payload']
          as Map<String, dynamic>;
      expect(payload['senderId'], userId);
      expect(payload['receiverId'], peerId);
      expect(payload['type'], reactionType);
      expect(
        payload['id'],
        reactionEventId(targetMessageId: 'msg-1', reactorId: userId),
      );
      expect(
        payload['message'],
        isA<String>().having((m) => m.isNotEmpty, 'nonEmpty', true),
      );
      expect(await db.query('pending_messages'), isEmpty);
    });

    test('toggleReaction queues pending direct row on failure', () async {
      postman.directSuccess = false;
      final service = ReactionService.direct(
        userId: userId,
        keyManager: keyManager,
        peerId: peerId,
      );
      await service.toggleReaction(targetMessageId: 'msg-2', emoji: '❤️');

      expect(postman.directCalls.length, 1);
      final rows = await db.query(
        'pending_messages',
        where: 'type = ?',
        whereArgs: [reactionType],
      );
      expect(rows.length, 1);
      expect(rows.first['senderId'], userId);
      expect(rows.first['receiverId'], peerId);
      expect(
        rows.first['id'],
        reactionEventId(targetMessageId: 'msg-2', reactorId: userId),
      );
      expect(rows.first['message'], isA<String>());
    });

    test('processPendingForPeer delivers pending direct reaction', () async {
      await db.insert('pending_messages', {
        'id': reactionEventId(targetMessageId: 'msg-3', reactorId: userId),
        'senderId': userId,
        'receiverId': peerId,
        'message': 'direct-ciphertext',
        'type': reactionType,
        'timestamp': 1000,
        'status': 'pending',
      });

      final ok = await ReactionService.processPendingForPeer(
        userId: userId,
        peerId: peerId,
        keyManager: keyManager,
      );

      expect(ok, isTrue);
      expect(postman.directCalls.length, 1);
      final payload = postman.directCalls.first['payload']
          as Map<String, dynamic>;
      expect(payload['receiverId'], peerId);
      expect(payload['type'], reactionType);
      expect(await db.query('pending_messages'), isEmpty);
    });

    test('processGlobalPendingDirect flushes delivered rows', () async {
      await db.insert('pending_messages', {
        'id': reactionEventId(targetMessageId: 'msg-4', reactorId: userId),
        'senderId': userId,
        'receiverId': peerId,
        'message': 'direct-ciphertext',
        'type': reactionType,
        'timestamp': 1000,
        'status': 'pending',
      });

      final ok = await ReactionService.processGlobalPendingDirect(
        userId: userId,
        keyManager: keyManager,
      );

      expect(ok, isTrue);
      expect(postman.directCalls.length, 1);
      expect(await db.query('pending_messages'), isEmpty);
    });

    test('processGlobalPendingDirect keeps row when delivery fails', () async {
      await db.insert('pending_messages', {
        'id': reactionEventId(targetMessageId: 'msg-5', reactorId: userId),
        'senderId': userId,
        'receiverId': peerId,
        'message': 'direct-ciphertext',
        'type': reactionType,
        'timestamp': 1000,
        'status': 'pending',
      });
      postman.directSuccess = false;

      final ok = await ReactionService.processGlobalPendingDirect(
        userId: userId,
        keyManager: keyManager,
      );

      expect(ok, isFalse);
      final rows = await db.query('pending_messages');
      expect(rows.length, 1);
      expect(
        rows.first['id'],
        reactionEventId(targetMessageId: 'msg-5', reactorId: userId),
      );
    });
  });

  group('ReactionService group delivery', () {
    const userId = 'me.onion';
    const peerId = 'peer.onion';
    const groupId = 'group-1';

    late Database db;
    late KeyManager keyManager;
    late _FakePostman postman;
    late SideChannelTransport transport;
    late _FakeGroupService groupService;

    setUp(() async {
      db = await _openTestDb();
      DBHelper.setDatabaseForTest(db);
      PendingMessageDbHelper.setDatabaseForTest(db);
      MessageReactionsDb.debugDatabase = db;
      keyManager = KeyManager.fromIdentity(await IdentityKeyPair.generate());
      await _insertPeerIdentity(db, peerId);
      postman = _FakePostman();
      transport = SideChannelTransport(
        userId: userId,
        outbox: const PendingSideChannelQueue(),
        postman: postman,
        maxAttempts: 1,
      );
      groupService = _FakeGroupService(
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
      ReactionService.resetForTest();
      ReactionService.configure(transport: transport);
    });

    tearDown(() async {
      await db.close();
      DBHelper.setDatabaseForTest(null);
      PendingMessageDbHelper.setDatabaseForTest(null);
      MessageReactionsDb.debugDatabase = null;
      ReactionService.resetForTest();
    });

    test('toggleReaction delivers group reaction to other members on success',
        () async {
      final service = ReactionService.group(
        userId: userId,
        keyManager: keyManager,
        groupId: groupId,
        groupService: groupService,
      );
      await service.toggleReaction(targetMessageId: 'msg-g1', emoji: '👍');

      expect(postman.groupCalls.length, 1);
      final payload = postman.groupCalls.first['payload']
          as Map<String, dynamic>;
      expect(payload['groupId'], groupId);
      expect(payload['receiverId'], peerId);
      expect(payload['senderId'], userId);
      expect(payload['type'], groupReactionType);
      expect(
        payload['id'],
        reactionEventId(targetMessageId: 'msg-g1', reactorId: userId),
      );
      expect(
        payload['message'],
        isA<String>().having((m) => m.isNotEmpty, 'nonEmpty', true),
      );
      expect(await db.query('pending_messages'), isEmpty);
    });

    test('toggleReaction queues pending group row per target on failure',
        () async {
      postman.groupSuccess = false;
      final service = ReactionService.group(
        userId: userId,
        keyManager: keyManager,
        groupId: groupId,
        groupService: groupService,
      );
      await service.toggleReaction(targetMessageId: 'msg-g2', emoji: '❤️');

      final rows = await db.query(
        'pending_messages',
        where: 'type = ?',
        whereArgs: [groupReactionType],
      );
      expect(rows.length, 1);
      expect(rows.first['senderId'], userId);
      expect(rows.first['receiverId'], peerId);
      expect(rows.first['groupId'], groupId);
      expect(rows.first['targetMemberId'], peerId);
      final eventId = reactionEventId(
        targetMessageId: 'msg-g2',
        reactorId: userId,
      );
      expect(rows.first['id'], '${eventId}__$peerId');
    });

    test(
        'processGlobalPendingGroup flushes delivered group rows with stripped event id',
        () async {
      final eventId = reactionEventId(
        targetMessageId: 'msg-g3',
        reactorId: userId,
      );
      await db.insert('pending_messages', {
        'id': '${eventId}__$peerId',
        'senderId': userId,
        'receiverId': peerId,
        'message': 'group-ciphertext',
        'type': groupReactionType,
        'timestamp': 1000,
        'status': 'pending',
        'groupId': groupId,
        'targetMemberId': peerId,
      });

      final ok = await ReactionService.processGlobalPendingGroup(
        userId: userId,
        keyManager: keyManager,
      );

      expect(ok, isTrue);
      expect(postman.groupCalls.length, 1);
      final payload = postman.groupCalls.first['payload']
          as Map<String, dynamic>;
      expect(payload['groupId'], groupId);
      expect(payload['type'], groupReactionType);
      expect(payload['id'], eventId);
      expect(payload['receiverId'], peerId);
      expect(await db.query('pending_messages'), isEmpty);
    });

    test('processGlobalPendingGroup keeps row when delivery fails', () async {
      postman.groupSuccess = false;
      final eventId = reactionEventId(
        targetMessageId: 'msg-g4',
        reactorId: userId,
      );
      await db.insert('pending_messages', {
        'id': '${eventId}__$peerId',
        'senderId': userId,
        'receiverId': peerId,
        'message': 'group-ciphertext',
        'type': groupReactionType,
        'timestamp': 1000,
        'status': 'pending',
        'groupId': groupId,
        'targetMemberId': peerId,
      });

      final ok = await ReactionService.processGlobalPendingGroup(
        userId: userId,
        keyManager: keyManager,
      );

      expect(ok, isFalse);
      final rows = await db.query('pending_messages');
      expect(rows.length, 1);
      expect(rows.first['id'], '${eventId}__$peerId');
    });
  });
}
