import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/constants/group_constants.dart';
import 'package:prysm/crypto/group_crypto.dart';
import 'package:prysm/crypto/identity.dart';
import 'package:prysm/crypto/ratchet/session_store.dart';
import 'package:prysm/services/group_control_channel.dart';
import 'package:prysm/services/group_key_provider.dart';
import 'package:prysm/services/group_service.dart';
import 'package:prysm/services/pending_side_channel_queue.dart';
import 'package:prysm/services/side_channel_postman.dart';
import 'package:prysm/services/side_channel_transport.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/util/group_sender_index_store.dart';
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
          CREATE TABLE group_members (
            groupId TEXT NOT NULL,
            memberId TEXT NOT NULL,
            role TEXT NOT NULL,
            joinedAt INTEGER NOT NULL,
            PRIMARY KEY (groupId, memberId)
          )
        ''');
        await db.execute('''
          CREATE TABLE group_keys (
            groupId TEXT PRIMARY KEY,
            encryptedKey TEXT NOT NULL,
            keyVersion INTEGER NOT NULL DEFAULT 1
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
        await GroupSenderIndexStore.ensureTable(db);
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
  final List<Map<String, dynamic>> groupCalls = [];
  bool groupSuccess = true;

  @override
  Future<void> postDirect({
    required String peerId,
    required Map<String, dynamic> payload,
    Duration timeout = const Duration(seconds: 30),
  }) async {}

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

  void clear() => groupCalls.clear();
}

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('GroupService delegates to GroupKeyProvider and GroupControlChannel', () {
    const userId = 'me.onion';
    const peerId = 'peer.onion';

    late Database db;
    late KeyManager keyManager;
    late GroupKeyProvider keyProvider;
    late _FakePostman postman;
    late GroupControlChannel controlChannel;
    late GroupService service;

    setUp(() async {
      db = await _openTestDb();
      DBHelper.setDatabaseForTest(db);
      PendingMessageDbHelper.setDatabaseForTest(db);
      keyManager = KeyManager.fromIdentity(await IdentityKeyPair.generate());
      keyProvider = GroupKeyProvider(keyManager: keyManager);
      postman = _FakePostman();
      controlChannel = GroupControlChannel(
        userId: userId,
        keyManager: keyManager,
        keyProvider: keyProvider,
        transport: SideChannelTransport(
          userId: userId,
          outbox: const PendingSideChannelQueue(),
          postman: postman,
        ),
      );
      service = GroupService(
        userId: userId,
        keyManager: keyManager,
        keyProvider: keyProvider,
        controlChannel: controlChannel,
      );
    });

    tearDown(() async {
      await db.close();
      DBHelper.setDatabaseForTest(null);
      PendingMessageDbHelper.setDatabaseForTest(null);
    });

    test('getDecryptedGroupKey / invalidateGroupKeyCache delegate to the injected GroupKeyProvider', () async {
      await db.insert('groups', {
        'id': 'g1',
        'name': 'Group One',
        'createdBy': userId,
        'createdAt': 1000,
      });
      final rawKey = GroupCryptoV2.generateGroupKey();
      final encrypted = await GroupCryptoV2.encryptGroupKeyForStorage(rawKey, keyManager.identity);
      await DBHelper.upsertGroupKey(groupId: 'g1', encryptedKey: encrypted, keyVersion: 1);

      expect(await service.getDecryptedGroupKey('g1'), equals(rawKey));

      await db.update('group_keys', {'encryptedKey': 'not-valid'}, where: 'groupId = ?', whereArgs: ['g1']);
      // Still cached (same version) via the shared provider.
      expect(await service.getDecryptedGroupKey('g1'), equals(rawKey));

      service.invalidateGroupKeyCache('g1');
      expect(await service.getDecryptedGroupKey('g1'), isNull);
    });

    test('createGroup delegates invite sending to the control channel', () async {
      await _insertPeerIdentity(db, peerId);

      final group = await service.createGroup('Squad', [peerId]);

      expect(postman.groupCalls.length, 1);
      final payload = postman.groupCalls.first['payload'] as Map<String, dynamic>;
      expect(payload['type'], groupInviteType);
      expect(payload['receiverId'], peerId);

      final groupRow = await DBHelper.getGroupById(group.id);
      expect(groupRow, isNotNull);
      final members = await DBHelper.getGroupMembers(group.id);
      expect(members.map((m) => m['memberId']), containsAll([userId, peerId]));
    });

    test('addMember re-syncs invites for all members via the control channel', () async {
      await _insertPeerIdentity(db, peerId);
      const newMemberId = 'new.onion';
      await _insertPeerIdentity(db, newMemberId);

      final group = await service.createGroup('Squad', [peerId]);
      postman.clear();

      await service.addMember(group.id, newMemberId);

      // syncMemberInvites re-sends to every non-self member: peer + new member.
      expect(postman.groupCalls.length, 2);
      final targets = postman.groupCalls.map((c) => c['targetMemberId']).toSet();
      expect(targets, {peerId, newMemberId});
      for (final call in postman.groupCalls) {
        expect((call['payload'] as Map)['type'], groupInviteType);
      }
    });

    test('removeMember sends key rotate + member removed to the removed and remaining members', () async {
      await _insertPeerIdentity(db, peerId);
      const otherMemberId = 'other.onion';
      await _insertPeerIdentity(db, otherMemberId);

      final group = await service.createGroup('Squad', [peerId, otherMemberId]);
      postman.clear();

      await service.removeMember(group.id, peerId);

      final types = postman.groupCalls.map((c) => (c['payload'] as Map)['type']).toSet();
      expect(types, {groupKeyRotateType, groupMemberRemovedType});
      final targets = postman.groupCalls.map((c) => c['targetMemberId']).toSet();
      // Removed member is told directly, and the remaining member is updated.
      expect(targets, {peerId, otherMemberId});
    });

    test('updateGroupName sends a profile update to other members', () async {
      await _insertPeerIdentity(db, peerId);
      final group = await service.createGroup('Squad', [peerId]);
      postman.clear();

      await service.updateGroupName(group.id, 'Renamed Squad');

      expect(postman.groupCalls.length, 1);
      final payload = postman.groupCalls.first['payload'] as Map<String, dynamic>;
      expect(payload['type'], groupProfileUpdateType);
      expect(payload['targetMemberId'] ?? postman.groupCalls.first['targetMemberId'], peerId);
    });

    test('processPendingControlMessages delegates the retry loop to the control channel', () async {
      await _insertPeerIdentity(db, peerId);
      postman.groupSuccess = false;
      await service.createGroup('Squad', [peerId]);
      expect(await db.query('pending_messages'), hasLength(1));
      postman.clear();
      postman.groupSuccess = true;

      final delivered = await service.processPendingControlMessages();

      expect(delivered, isTrue);
      expect(postman.groupCalls.length, 1);
      expect(await db.query('pending_messages'), isEmpty);
    });
  });
}
