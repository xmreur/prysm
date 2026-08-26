import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/constants/group_constants.dart';
import 'package:prysm/crypto/group_crypto.dart';
import 'package:prysm/crypto/identity.dart';
import 'package:prysm/crypto/ratchet/session_store.dart';
import 'package:prysm/database/conversation_preferences_db.dart';
import 'package:prysm/database/message_schema_migrations.dart';
import 'package:prysm/database/messages.dart';
import 'package:prysm/services/group_control_channel.dart';
import 'package:prysm/services/group_key_provider.dart';
import 'package:prysm/services/group_service.dart';
import 'package:prysm/services/message_modify_service.dart';
import 'package:prysm/services/pending_side_channel_queue.dart';
import 'package:prysm/services/side_channel_postman.dart';
import 'package:prysm/services/side_channel_transport.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/util/group_sender_index_store.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/message_modify_payload.dart';
import 'package:prysm/util/pending_message_db_helper.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<Database> _openChatDb() async {
  return databaseFactory.openDatabase(
    '${inMemoryDatabasePath}_mod_chat_${DateTime.now().microsecondsSinceEpoch}',
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
            createdAt INTEGER NOT NULL,
            onlyAdminsCanAdd INTEGER NOT NULL DEFAULT 1
          )
        ''');
        await db.execute('''
          CREATE TABLE group_members (
            groupId TEXT NOT NULL,
            memberId TEXT NOT NULL,
            role TEXT NOT NULL,
            joinedAt INTEGER NOT NULL,
            muted INTEGER NOT NULL DEFAULT 0,
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
        await ConversationPreferencesDb.createTable(db);
        await GroupSenderIndexStore.ensureTable(db);
        await RatchetSessionStore.ensureTable(db);
      },
    ),
  );
}

Future<void> _insertIdentity(
  Database db,
  String peerId,
  IdentityKeyPair pair,
) async {
  await db.insert('users', {
    'id': peerId,
    'identityJson': jsonEncode(await pair.toPublicJson()),
  });
}

Future<void> _insertGroup({
  required Database db,
  required String groupId,
  required String createdBy,
  required List<({String id, String role, int muted})> members,
}) async {
  await db.insert('groups', {
    'id': groupId,
    'name': 'Squad',
    'createdBy': createdBy,
    'createdAt': 1000,
    'onlyAdminsCanAdd': 1,
  });
  for (final m in members) {
    await db.insert('group_members', {
      'groupId': groupId,
      'memberId': m.id,
      'role': m.role,
      'joinedAt': 1000,
      'muted': m.muted,
    });
  }
}

class _FakePostman implements SideChannelPostman {
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
  }) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late Database chatDb;
  late Database messagesDb;
  late KeyManager keyManager;
  late GroupService service;

  const localId = 'me.onion';
  const memberId = 'member.onion';
  const adminId = 'admin.onion';
  const ownerId = 'owner.onion';
  const groupId = 'g1';

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    tempDir = Directory.systemTemp.createTempSync('group_moderation_test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async {
        if (call.method == 'getApplicationDocumentsDirectory' ||
            call.method == 'getTemporaryDirectory') {
          return tempDir.path;
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
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  setUp(() async {
    chatDb = await _openChatDb();
    DBHelper.setDatabaseForTest(chatDb);
    PendingMessageDbHelper.setDatabaseForTest(chatDb);
    messagesDb = await databaseFactory.openDatabase(
      '${inMemoryDatabasePath}_mod_msg_${DateTime.now().microsecondsSinceEpoch}',
      options: OpenDatabaseOptions(
        version: MessageSchemaMigrations.dbVersion,
        onCreate: MessageSchemaMigrations.onCreate,
      ),
    );
    MessagesDb.setDatabaseForTest(messagesDb);
    keyManager = KeyManager.fromIdentity(await IdentityKeyPair.generate());
    service = GroupService(userId: localId, keyManager: keyManager);
  });

  tearDown(() async {
    await chatDb.close();
    await messagesDb.close();
    DBHelper.setDatabaseForTest(null);
    PendingMessageDbHelper.setDatabaseForTest(null);
    MessagesDb.setDatabaseForTest(null);
  });

  Future<String> wrapControl(
    IdentityKeyPair sender,
    Map<String, dynamic> payload,
  ) async {
    return GroupCryptoV2.encryptControlPayload(
      jsonEncode(payload),
      sender,
      await keyManager.identity.agreePublicKey,
    );
  }

  group('inbound control', () {
    test('a member cannot mute another member', () async {
      final sender = await IdentityKeyPair.generate();
      await _insertIdentity(chatDb, memberId, sender);
      await _insertGroup(
        db: chatDb,
        groupId: groupId,
        createdBy: localId,
        members: [
          (id: localId, role: 'owner', muted: 0),
          (id: memberId, role: 'member', muted: 0),
          (id: adminId, role: 'member', muted: 0),
        ],
      );

      final wire = await wrapControl(sender, {
        'groupId': groupId,
        'memberId': adminId,
        'muted': 1,
      });
      await service.handleIncomingControlMessage(
        groupMemberMuteType,
        wire,
        memberId,
      );

      final rows = await DBHelper.getGroupMembers(groupId);
      expect(
        rows.firstWhere((m) => m['memberId'] == adminId)['muted'],
        0,
      );
    });

    test('invite from an existing member cannot promote local user', () async {
      final sender = await IdentityKeyPair.generate();
      await _insertIdentity(chatDb, memberId, sender);
      final groupKey = GroupCryptoV2.generateGroupKey();
      final encryptedForSelf = await GroupCryptoV2.encryptGroupKeyForStorage(
        groupKey,
        keyManager.identity,
      );
      await _insertGroup(
        db: chatDb,
        groupId: groupId,
        createdBy: memberId,
        members: [
          (id: localId, role: 'member', muted: 0),
          (id: memberId, role: 'member', muted: 0),
        ],
      );
      await DBHelper.upsertGroupKey(
        groupId: groupId,
        encryptedKey: encryptedForSelf,
        keyVersion: 1,
      );

      final encryptedGroupKey = await GroupCryptoV2.encryptGroupKeyForStorage(
        groupKey,
        sender,
        peerAgreePublic: await keyManager.identity.agreePublicKey,
      );
      final wire = await wrapControl(sender, {
        'groupId': groupId,
        'name': 'Squad',
        'createdBy': memberId,
        'keyVersion': 1,
        'encryptedGroupKey': encryptedGroupKey,
        'onlyAdminsCanAdd': 1,
        'members': [
          {'id': localId, 'role': 'admin', 'muted': '0'},
          {'id': memberId, 'role': 'owner', 'muted': '0'},
        ],
      });
      await service.handleIncomingControlMessage(
        groupInviteType,
        wire,
        memberId,
      );

      final rows = await DBHelper.getGroupMembers(groupId);
      expect(
        rows.firstWhere((m) => m['memberId'] == localId)['role'],
        'member',
      );
      expect(
        rows.firstWhere((m) => m['memberId'] == memberId)['role'],
        'member',
      );
    });
  });

  group('leave and transfer', () {
    GroupService serviceWithPostman() {
      final keyProvider = GroupKeyProvider(keyManager: keyManager);
      return GroupService(
        userId: localId,
        keyManager: keyManager,
        keyProvider: keyProvider,
        controlChannel: GroupControlChannel(
          userId: localId,
          keyManager: keyManager,
          keyProvider: keyProvider,
          transport: SideChannelTransport(
            userId: localId,
            outbox: const PendingSideChannelQueue(),
            postman: _FakePostman(),
          ),
        ),
      );
    }

    test('owner cannot leave until ownership is transferred', () async {
      final leaving = serviceWithPostman();
      await _insertIdentity(chatDb, memberId, await IdentityKeyPair.generate());
      final groupKey = GroupCryptoV2.generateGroupKey();
      await DBHelper.upsertGroupKey(
        groupId: groupId,
        encryptedKey: await GroupCryptoV2.encryptGroupKeyForStorage(
          groupKey,
          keyManager.identity,
        ),
        keyVersion: 1,
      );
      await _insertGroup(
        db: chatDb,
        groupId: groupId,
        createdBy: localId,
        members: [
          (id: localId, role: 'owner', muted: 0),
          (id: memberId, role: 'member', muted: 0),
        ],
      );

      await expectLater(
        leaving.leaveGroup(groupId),
        throwsA(
          isA<GroupServiceException>().having(
            (e) => e.message,
            'message',
            contains('transfer ownership'),
          ),
        ),
      );

      await leaving.transferOwnership(
        groupId: groupId,
        newOwnerId: memberId,
      );
      await leaving.leaveGroup(groupId);
      expect(await DBHelper.getGroupById(groupId), isNull);
    });

    test('an admin can leave without transferring', () async {
      final leaving = serviceWithPostman();
      await _insertIdentity(chatDb, ownerId, await IdentityKeyPair.generate());
      await DBHelper.upsertGroupKey(
        groupId: groupId,
        encryptedKey: await GroupCryptoV2.encryptGroupKeyForStorage(
          GroupCryptoV2.generateGroupKey(),
          keyManager.identity,
        ),
        keyVersion: 1,
      );
      await _insertGroup(
        db: chatDb,
        groupId: groupId,
        createdBy: ownerId,
        members: [
          (id: ownerId, role: 'owner', muted: 0),
          (id: localId, role: 'admin', muted: 0),
        ],
      );

      await leaving.leaveGroup(groupId);
      expect(await DBHelper.getGroupById(groupId), isNull);
    });
  });

  group('inbound delete-for-everyone', () {
    Future<Uint8List> storeGroupKey() async {
      final groupKey = GroupCryptoV2.generateGroupKey();
      await DBHelper.upsertGroupKey(
        groupId: groupId,
        encryptedKey: await GroupCryptoV2.encryptGroupKeyForStorage(
          groupKey,
          keyManager.identity,
        ),
        keyVersion: 1,
      );
      return groupKey;
    }

    Future<InboundModifyOutcome> applyDelete({
      required String actorId,
      required Uint8List groupKey,
      required String targetWireId,
    }) async {
      final encrypted = await GroupCryptoV2.encryptText(
        groupKey,
        MessageModifyPayload(
          targetMessageId: targetWireId,
          action: 'delete',
          modifiedAt: 9,
        ).encode(),
      );
      return MessageModifyService.applyInbound(
        keyManager: keyManager,
        localUserId: localId,
        encrypted: encrypted,
        senderId: actorId,
        type: groupMessageModifyType,
        groupId: groupId,
        groupService: service,
      );
    }

    test('admin delete of a member message is accepted', () async {
      final groupKey = await storeGroupKey();
      await _insertGroup(
        db: chatDb,
        groupId: groupId,
        createdBy: ownerId,
        members: [
          (id: ownerId, role: 'owner', muted: 0),
          (id: adminId, role: 'admin', muted: 0),
          (id: memberId, role: 'member', muted: 0),
          (id: localId, role: 'member', muted: 0),
        ],
      );
      await MessagesDb.insertMessage({
        'id': 'wire-1',
        'senderId': memberId,
        'receiverId': localId,
        'groupId': groupId,
        'message': 'cipher',
        'type': groupTextType,
        'status': 'sent',
        'timestamp': 1,
      });

      final outcome = await applyDelete(
        actorId: adminId,
        groupKey: groupKey,
        targetWireId: 'wire-1',
      );
      expect(outcome, InboundModifyOutcome.applied);
      final rows = await MessagesDb.getMessageById('wire-1', groupId: groupId);
      expect(rows.single['deletedAt'], isNotNull);
    });

    test('admin delete of an owner message is rejected', () async {
      final groupKey = await storeGroupKey();
      await _insertGroup(
        db: chatDb,
        groupId: groupId,
        createdBy: ownerId,
        members: [
          (id: ownerId, role: 'owner', muted: 0),
          (id: adminId, role: 'admin', muted: 0),
          (id: localId, role: 'member', muted: 0),
        ],
      );
      await MessagesDb.insertMessage({
        'id': 'wire-1',
        'senderId': ownerId,
        'receiverId': localId,
        'groupId': groupId,
        'message': 'cipher',
        'type': groupTextType,
        'status': 'sent',
        'timestamp': 1,
      });

      final outcome = await applyDelete(
        actorId: adminId,
        groupKey: groupKey,
        targetWireId: 'wire-1',
      );
      expect(outcome, InboundModifyOutcome.ownershipRejected);
      final rows = await MessagesDb.getMessageById('wire-1', groupId: groupId);
      expect(rows.single['deletedAt'], isNull);
    });
  });
}
