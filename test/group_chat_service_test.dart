// Characterization test for GroupChatService's outbound send path (Fase
// 3.3), fixed against the CURRENT implementation before the transport
// dependency (TransportProvider.postMessageOrFallback, called statically)
// is replaced by a ctor-injectable SideChannelPostman. GroupChatService had
// no dedicated test file prior to this change.
//
// TorRuntimeGate.blocked short-circuits _sendOverTor before it reaches the
// transport, giving a deterministic, network-free way to characterize the
// "delivery unavailable -> queued for every target" path (same technique
// used by chat_service_characterization_test.dart for ChatService).
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/constants/group_constants.dart';
import 'package:prysm/crypto/ratchet/session_store.dart';
import 'package:prysm/crypto/identity.dart';
import 'package:prysm/database/messages.dart';
import 'package:prysm/models/group.dart';
import 'package:prysm/services/group_chat_service.dart';
import 'package:prysm/services/side_channel_postman.dart';
import 'package:prysm/services/group_service.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/util/group_sender_index_store.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/pending_message_db_helper.dart';
import 'package:prysm/util/tor_lifecycle_state.dart';
import 'package:prysm/util/tor_runtime_gate.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

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
  Future<bool> isMember(String groupId) async => true;

  @override
  Future<Uint8List?> getDecryptedGroupKey(String groupId) async => groupKey;

  @override
  Future<List<GroupMember>> getMembers(String groupId) async => members;
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
  await RatchetSessionStore.ensureTable(db);
  await GroupSenderIndexStore.ensureTable(db);
  await db.execute('''
    CREATE TABLE conversation_preferences (
      conversationId TEXT PRIMARY KEY,
      isPinned INTEGER NOT NULL DEFAULT 0,
      pinnedAt INTEGER,
      isArchived INTEGER NOT NULL DEFAULT 0,
      archivedAt INTEGER,
      disappearingTimerSeconds INTEGER
    )
  ''');
  return db;
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
  return db;
}

class _FakePostmanCall {
  _FakePostmanCall({
    required this.targetMemberId,
    required this.payload,
    required this.timeout,
  });

  final String targetMemberId;
  final Map<String, dynamic> payload;
  final Duration timeout;
}

class _FakePostman implements SideChannelPostman {
  final groupCalls = <_FakePostmanCall>[];

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
    groupCalls.add(
      _FakePostmanCall(
        targetMemberId: targetMemberId,
        payload: payload,
        timeout: timeout,
      ),
    );
  }
}

void main() {
  late Directory docsDir;

  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;

    // MessagesDb.getMessageById unconditionally probes MessageBlobStore,
    // which shells out to path_provider even for small inline payloads.
    docsDir = Directory.systemTemp.createTempSync('group_chat_service_char_test');
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
  const groupId = 'g1';
  const memberA = 'a.onion';
  const memberB = 'b.onion';

  late Database pendingDb;
  late Database dbHelperDb;
  late Database messagesDb;
  late KeyManager keyManager;
  late GroupChatService service;

  setUp(() async {
    pendingDb = await _openPendingDb();
    PendingMessageDbHelper.setDatabaseForTest(pendingDb);

    dbHelperDb = await _openDbHelperDb();
    DBHelper.setDatabaseForTest(dbHelperDb);

    messagesDb = await _openMessagesDb();
    MessagesDb.setDatabaseForTest(messagesDb);

    keyManager = KeyManager.fromIdentity(await IdentityKeyPair.generate());

    final fakeGroupService = _FakeGroupService(
      userId: userId,
      keyManager: keyManager,
      groupKey: Uint8List.fromList(List.generate(32, (i) => i)),
      members: [
        GroupMember(
          groupId: groupId,
          memberId: userId,
          role: GroupRole.admin,
          joinedAt: 0,
        ),
        GroupMember(
          groupId: groupId,
          memberId: memberA,
          role: GroupRole.member,
          joinedAt: 0,
        ),
        GroupMember(
          groupId: groupId,
          memberId: memberB,
          role: GroupRole.member,
          joinedAt: 0,
        ),
      ],
    );

    service = GroupChatService(
      userId: userId,
      groupId: groupId,
      keyManager: keyManager,
      groupService: fakeGroupService,
    );

    // Deterministic, network-free "send fails" path: GroupChatService checks
    // TorRuntimeGate.blocked before touching the transport, so blocking it
    // characterizes the pending-queue path without a real Tor socket.
    TorRuntimeGate.resetForTest(lifecycle: TorLifecycleState.stopped);
  });

  tearDown(() async {
    service.dispose();

    await pendingDb.close();
    PendingMessageDbHelper.setDatabaseForTest(null);

    await dbHelperDb.close();
    DBHelper.setDatabaseForTest(null);

    await messagesDb.close();
    MessagesDb.setDatabaseForTest(null);

    TorRuntimeGate.resetForTest();
  });

  group('sendTextMessage', () {
    test(
      'queues one pending row per member when the transport is blocked',
      () async {
        final id = await service.sendTextMessage('hello group');
        expect(id, isNotNull);

        final stored = await MessagesDb.getMessageById(id!, groupId: groupId);
        expect(stored, hasLength(1));
        expect(stored.first['status'], 'failed');

        final pending = await PendingMessageDbHelper.getPendingMessages(
          groupId: groupId,
        );
        expect(pending, hasLength(2));
        final targets = pending.map((m) => m['targetMemberId']).toSet();
        expect(targets, {memberA, memberB});
        for (final row in pending) {
          expect(row['type'], groupTextType);
        }
      },
    );
  });

  group('SideChannelPostman injection (Fase 3.3)', () {
    test('sendTextMessage delivers through the injected postman', () async {
      TorRuntimeGate.resetForTest();
      final postman = _FakePostman();
      final fakeGroupService = _FakeGroupService(
        userId: userId,
        keyManager: keyManager,
        groupKey: Uint8List.fromList(List.generate(32, (i) => i)),
        members: [
          GroupMember(
            groupId: groupId,
            memberId: userId,
            role: GroupRole.admin,
            joinedAt: 0,
          ),
          GroupMember(
            groupId: groupId,
            memberId: memberA,
            role: GroupRole.member,
            joinedAt: 0,
          ),
        ],
      );
      final injectedService = GroupChatService(
        userId: userId,
        groupId: groupId,
        keyManager: keyManager,
        groupService: fakeGroupService,
        postman: postman,
      );
      addTearDown(injectedService.dispose);

      final id = await injectedService.sendTextMessage('hello group');

      expect(postman.groupCalls, hasLength(1));
      final call = postman.groupCalls.single;
      expect(call.targetMemberId, memberA);
      expect(call.payload['id'], id);
      expect(call.payload['type'], groupTextType);
      expect(call.timeout, const Duration(seconds: 30));

      final stored = await MessagesDb.getMessageById(id!, groupId: groupId);
      expect(stored.first['status'], 'sent');
    });

    test('startSendQueue skips soft-deleted pending messages', () async {
      TorRuntimeGate.resetForTest();
      final postman = _FakePostman();
      const wireId = 'msg-deleted';

      await MessagesDb.insertMessage({
        'id': wireId,
        'senderId': userId,
        'receiverId': userId,
        'groupId': groupId,
        'message': 'self-cipher',
        'type': groupTextType,
        'status': 'failed',
        'timestamp': 1,
      }, notifyListeners: false);

      await PendingMessageDbHelper.insertPendingMessage({
        'id': '${wireId}__$memberA',
        'senderId': userId,
        'receiverId': memberA,
        'message': 'peer-cipher-a',
        'type': groupTextType,
        'timestamp': 1,
        'status': 'pending',
        'groupId': groupId,
        'targetMemberId': memberA,
      });
      await PendingMessageDbHelper.insertPendingMessage({
        'id': '${wireId}__$memberB',
        'senderId': userId,
        'receiverId': memberB,
        'message': 'peer-cipher-b',
        'type': groupTextType,
        'timestamp': 1,
        'status': 'pending',
        'groupId': groupId,
        'targetMemberId': memberB,
      });

      await MessagesDb.softDeleteMessage(
        wireId,
        groupId: groupId,
        deletedAt: 5000,
      );

      final fakeGroupService = _FakeGroupService(
        userId: userId,
        keyManager: keyManager,
        groupKey: Uint8List.fromList(List.generate(32, (i) => i)),
        members: [
          GroupMember(
            groupId: groupId,
            memberId: userId,
            role: GroupRole.admin,
            joinedAt: 0,
          ),
          GroupMember(
            groupId: groupId,
            memberId: memberA,
            role: GroupRole.member,
            joinedAt: 0,
          ),
          GroupMember(
            groupId: groupId,
            memberId: memberB,
            role: GroupRole.member,
            joinedAt: 0,
          ),
        ],
      );
      final injectedService = GroupChatService(
        userId: userId,
        groupId: groupId,
        keyManager: keyManager,
        groupService: fakeGroupService,
        postman: postman,
      );
      addTearDown(injectedService.dispose);
      await injectedService.initialize();

      injectedService.startSendQueue();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(postman.groupCalls, isEmpty);
      final remaining = await PendingMessageDbHelper.getPendingMessages(
        groupId: groupId,
      );
      expect(remaining, isEmpty);
    });
  });
}
