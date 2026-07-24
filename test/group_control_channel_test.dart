import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/constants/group_constants.dart';
import 'package:prysm/crypto/group_crypto.dart';
import 'package:prysm/crypto/identity.dart';
import 'package:prysm/crypto/ratchet/session_store.dart';
import 'package:prysm/services/group_control_channel.dart';
import 'package:prysm/services/group_key_provider.dart';
import 'package:prysm/services/pending_side_channel_queue.dart';
import 'package:prysm/services/side_channel_postman.dart';
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
            keyVersion INTEGER NOT NULL DEFAULT 1,
            FOREIGN KEY (groupId) REFERENCES groups(id) ON DELETE CASCADE
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
  bool groupSuccess = true;

  @override
  Future<void> postDirect({
    required String peerId,
    required Map<String, dynamic> payload,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    directCalls.add({'peerId': peerId, 'payload': payload});
  }

  @override
  Future<void> postGroup({
    required String targetMemberId,
    required Map<String, dynamic> payload,
    Duration timeout = const Duration(seconds: 30),
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

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('GroupControlChannel', () {
    const userId = 'me.onion';
    const peerId = 'peer.onion';
    const groupId = 'g1';

    late Database db;
    late KeyManager keyManager;
    late GroupKeyProvider keyProvider;
    late _FakePostman postman;
    late GroupControlChannel channel;

    setUp(() async {
      db = await _openTestDb();
      DBHelper.setDatabaseForTest(db);
      PendingMessageDbHelper.setDatabaseForTest(db);
      keyManager = KeyManager.fromIdentity(await IdentityKeyPair.generate());
      keyProvider = GroupKeyProvider(keyManager: keyManager);
      postman = _FakePostman();
      channel = GroupControlChannel(
        userId: userId,
        keyManager: keyManager,
        keyProvider: keyProvider,
        transport: SideChannelTransport(
          userId: userId,
          outbox: const PendingSideChannelQueue(),
          postman: postman,
        ),
      );
      await db.insert('groups', {
        'id': groupId,
        'name': 'Group One',
        'createdBy': userId,
        'createdAt': 1000,
      });
    });

    tearDown(() async {
      await db.close();
      DBHelper.setDatabaseForTest(null);
      PendingMessageDbHelper.setDatabaseForTest(null);
    });

    test('sendInvite posts an encrypted invite to a known peer', () async {
      await _insertPeerIdentity(db, peerId);
      final groupKey = GroupCryptoV2.generateGroupKey();

      await channel.sendInvite(
        groupId: groupId,
        name: 'Group One',
        members: const [
          {'id': userId, 'role': 'admin'},
          {'id': peerId, 'role': 'member'},
        ],
        groupKey: groupKey,
        keyVersion: 1,
        targetMemberId: peerId,
      );

      expect(postman.groupCalls.length, 1);
      final payload = postman.groupCalls.first['payload'] as Map<String, dynamic>;
      expect(payload['receiverId'], peerId);
      expect(payload['groupId'], groupId);
      expect(payload['type'], groupInviteType);
      expect(payload['message'], isA<String>());
      expect(await db.query('pending_messages'), isEmpty);
    });

    test('sendInvite queues an unencrypted marker when the peer key is unknown', () async {
      final groupKey = GroupCryptoV2.generateGroupKey();

      await channel.sendInvite(
        groupId: groupId,
        name: 'Group One',
        members: const [
          {'id': userId, 'role': 'admin'},
          {'id': peerId, 'role': 'member'},
        ],
        groupKey: groupKey,
        keyVersion: 1,
        targetMemberId: peerId,
      );

      expect(postman.groupCalls, isEmpty);
      final rows = await db.query('pending_messages');
      expect(rows.length, 1);
      expect(rows.first['targetMemberId'], peerId);
      final stored = jsonDecode(rows.first['message'] as String) as Map<String, dynamic>;
      expect(stored['_pendingControl'], groupInviteType);
      expect(stored['groupId'], groupId);
    });

    test('sendInvite queues the attempted encrypted wire when delivery fails', () async {
      await _insertPeerIdentity(db, peerId);
      postman.groupSuccess = false;
      final groupKey = GroupCryptoV2.generateGroupKey();

      await channel.sendInvite(
        groupId: groupId,
        name: 'Group One',
        members: const [
          {'id': userId, 'role': 'admin'},
          {'id': peerId, 'role': 'member'},
        ],
        groupKey: groupKey,
        keyVersion: 1,
        targetMemberId: peerId,
      );

      expect(postman.groupCalls.length, 1);
      final attemptedMessage =
          postman.groupCalls.first['payload']['message'] as String;
      final rows = await db.query('pending_messages');
      expect(rows.length, 1);
      expect(rows.first['message'], attemptedMessage);
      expect(rows.first['type'], groupInviteType);
    });

    test('sendMemberRemoved posts the expected payload shape', () async {
      await _insertPeerIdentity(db, peerId);

      await channel.sendMemberRemoved(
        groupId: groupId,
        removedMemberId: 'removed.onion',
        keyVersion: 2,
        targetMemberId: peerId,
      );

      expect(postman.groupCalls.length, 1);
      final payload = postman.groupCalls.first['payload'] as Map<String, dynamic>;
      expect(payload['type'], groupMemberRemovedType);
      expect(payload['receiverId'], peerId);
      expect(await db.query('pending_messages'), isEmpty);
    });

    test(
        'processPendingControlMessages delivers an already-encrypted pending '
        'wire without re-encrypting it', () async {
      await _insertPeerIdentity(db, peerId);
      postman.groupSuccess = false;
      await channel.sendProfileUpdate(
        groupId: groupId,
        name: 'renamed',
        targetMemberId: peerId,
      );
      final queued = await db.query('pending_messages');
      expect(queued.length, 1);
      final queuedWire = queued.first['message'] as String;
      postman.clear();
      postman.groupSuccess = true;

      final delivered = await channel.processPendingControlMessages();

      expect(delivered, isTrue);
      expect(postman.groupCalls.length, 1);
      expect(postman.groupCalls.first['payload']['message'], queuedWire);
      expect(await db.query('pending_messages'), isEmpty);
    });

    test(
        'processPendingControlMessages resolves a queued invite once the '
        'peer key becomes known', () async {
      final groupKey = GroupCryptoV2.generateGroupKey();
      final encryptedForSelf = await GroupCryptoV2.encryptGroupKeyForStorage(
        groupKey,
        keyManager.identity,
      );
      await DBHelper.upsertGroupKey(
        groupId: groupId,
        encryptedKey: encryptedForSelf,
        keyVersion: 1,
      );

      await channel.sendInvite(
        groupId: groupId,
        name: 'Group One',
        members: const [
          {'id': userId, 'role': 'admin'},
          {'id': peerId, 'role': 'member'},
        ],
        groupKey: groupKey,
        keyVersion: 1,
        targetMemberId: peerId,
      );
      expect(postman.groupCalls, isEmpty);
      final queuedBefore = await db.query('pending_messages');
      expect(queuedBefore.length, 1);
      final rawMarker = queuedBefore.first['message'] as String;

      await _insertPeerIdentity(db, peerId);

      final delivered = await channel.processPendingControlMessages();

      expect(delivered, isTrue);
      expect(postman.groupCalls.length, 1);
      final sentWire = postman.groupCalls.first['payload']['message'] as String;
      expect(sentWire, isNot(equals(rawMarker)));
      expect(await db.query('pending_messages'), isEmpty);
    });

    test('processPendingControlMessages stops after three consecutive failures', () async {
      await _insertPeerIdentity(db, peerId);
      postman.groupSuccess = false;
      for (var i = 0; i < 5; i++) {
        await channel.sendProfileUpdate(
          groupId: groupId,
          name: 'n$i',
          targetMemberId: peerId,
        );
      }
      postman.clear();
      expect(await db.query('pending_messages'), hasLength(5));

      final delivered = await channel.processPendingControlMessages();

      expect(delivered, isFalse);
      expect(postman.groupCalls.length, 3);
      expect(await db.query('pending_messages'), hasLength(5));
    });

    test('processPendingControlMessages respects maxPerCycle on successful deliveries', () async {
      await _insertPeerIdentity(db, peerId);
      postman.groupSuccess = false;
      for (var i = 0; i < 5; i++) {
        await channel.sendProfileUpdate(
          groupId: groupId,
          name: 'n$i',
          targetMemberId: peerId,
        );
      }
      postman.clear();
      postman.groupSuccess = true;

      final delivered = await channel.processPendingControlMessages(maxPerCycle: 2);

      expect(delivered, isTrue);
      expect(postman.groupCalls.length, 2);
      expect(await db.query('pending_messages'), hasLength(3));
    });

    test('processPendingControlMessages does not count unresolved wires against maxPerCycle', () async {
      postman.groupSuccess = false;
      await channel.sendProfileUpdate(
        groupId: groupId,
        name: 'ghost',
        targetMemberId: 'ghost.onion',
      );

      await _insertPeerIdentity(db, peerId);
      for (var i = 0; i < 4; i++) {
        await channel.sendProfileUpdate(
          groupId: groupId,
          name: 'known$i',
          targetMemberId: peerId,
        );
      }
      postman.clear();
      expect(await db.query('pending_messages'), hasLength(5));

      postman.groupSuccess = true;
      final delivered = await channel.processPendingControlMessages(maxPerCycle: 4);

      expect(delivered, isTrue);
      expect(postman.groupCalls.length, 4);
      final remaining = await db.query('pending_messages');
      expect(remaining.length, 1);
      expect(remaining.first['targetMemberId'], 'ghost.onion');
    });
  });
}
