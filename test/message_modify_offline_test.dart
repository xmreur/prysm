import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/constants/group_constants.dart';
import 'package:prysm/services/message_modify_service.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/message_modify_payload.dart';
import 'package:prysm/util/message_modify_refresh_notifier.dart';
import 'package:prysm/util/pending_message_db_helper.dart';
import 'package:prysm/util/rsa_helper.dart';
import 'package:pointycastle/asymmetric/api.dart' show RSAPrivateKey, RSAPublicKey;
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
    MessageModifyService.postDirectOverride = null;
  });

  group('isPendingOutboundChatType', () {
    test('includes direct and group chat types', () {
      expect(isPendingOutboundChatType('text'), isTrue);
      expect(isPendingOutboundChatType(groupTextType), isTrue);
    });

    test('excludes side-channel types', () {
      expect(isPendingOutboundChatType(messageModifyType), isFalse);
      expect(isPendingOutboundChatType(reactionType), isFalse);
      expect(isPendingOutboundChatType(readReceiptType), isFalse);
    });
  });

  group('PendingMessageDbHelper outbound edit helpers', () {
    late Database db;

    setUp(() async {
      db = await _openPendingTestDb();
      PendingMessageDbHelper.setDatabaseForTest(db);
    });

    tearDown(() async {
      await db.close();
    });

    test('getPendingOutboundForWireId finds direct text pending', () async {
      await db.insert('pending_messages', {
        'id': 'msg-1',
        'senderId': 'me.onion',
        'receiverId': 'peer.onion',
        'message': 'old-ciphertext',
        'type': 'text',
        'timestamp': 1,
      });

      final row = await PendingMessageDbHelper.getPendingOutboundForWireId(
        'msg-1',
      );
      expect(row, isNotNull);
      expect(row!['message'], 'old-ciphertext');
    });

    test('getPendingOutboundForWireId ignores modify side-channels', () async {
      await db.insert('pending_messages', {
        'id': 'msg-1',
        'senderId': 'me.onion',
        'receiverId': 'peer.onion',
        'message': 'modify-ciphertext',
        'type': messageModifyType,
        'timestamp': 1,
      });

      final row = await PendingMessageDbHelper.getPendingOutboundForWireId(
        'msg-1',
      );
      expect(row, isNull);
    });

    test('updatePendingCiphertext replaces outbound payload', () async {
      await db.insert('pending_messages', {
        'id': 'msg-1',
        'senderId': 'me.onion',
        'receiverId': 'peer.onion',
        'message': 'old-ciphertext',
        'type': 'text',
        'timestamp': 1,
      });

      await PendingMessageDbHelper.updatePendingCiphertext(
        id: 'msg-1',
        encrypted: 'new-ciphertext',
      );

      final row = await PendingMessageDbHelper.getPendingOutboundForWireId(
        'msg-1',
      );
      expect(row!['message'], 'new-ciphertext');
    });

    test('getPendingGroupOutboundForWireId finds member rows', () async {
      const groupId = 'group-1';
      const wireId = 'msg-1';
      await db.insert('pending_messages', {
        'id': '${wireId}__peer-a.onion',
        'senderId': 'me.onion',
        'receiverId': 'peer-a.onion',
        'message': 'old-a',
        'type': groupTextType,
        'timestamp': 1,
        'groupId': groupId,
        'targetMemberId': 'peer-a.onion',
      });
      await db.insert('pending_messages', {
        'id': '${wireId}__peer-b.onion',
        'senderId': 'me.onion',
        'receiverId': 'peer-b.onion',
        'message': 'old-b',
        'type': groupTextType,
        'timestamp': 2,
        'groupId': groupId,
        'targetMemberId': 'peer-b.onion',
      });

      final rows = await PendingMessageDbHelper.getPendingGroupOutboundForWireId(
        wireId,
        groupId,
      );
      expect(rows.length, 2);
    });
  });

  group('MessageModifyService.syncDirectEditOutbound', () {
    late Database db;
    late KeyManager keyManager;
    late RSAPublicKey peerPublicKey;

    setUp(() async {
      db = await _openPendingTestDb();
      PendingMessageDbHelper.setDatabaseForTest(db);

      final pair = RSAHelper.generateKeyPair();
      keyManager = KeyManager.fromKeys(
        pair.privateKey as RSAPrivateKey,
        pair.publicKey as RSAPublicKey,
      );
      peerPublicKey = pair.publicKey as RSAPublicKey;
    });

    tearDown(() async {
      await db.close();
    });

    test('updates pending row and skips modify when outbound is pending', () async {
      const wireId = 'msg-1';
      await db.insert('pending_messages', {
        'id': wireId,
        'senderId': 'me.onion',
        'receiverId': 'peer.onion',
        'message': 'old-ciphertext',
        'type': 'text',
        'timestamp': 1,
      });

      var postCalled = false;
      MessageModifyService.postDirectOverride = ({
        required id,
        required encrypted,
        required timestamp,
        required peerId,
      }) async {
        postCalled = true;
        return false;
      };

      final service = MessageModifyService.direct(
        userId: 'me.onion',
        keyManager: keyManager,
        peerId: 'peer.onion',
      );
      final encryptedPeer = keyManager.encryptForPeer('edited', peerPublicKey);
      final payload = MessageModifyPayload(
        targetMessageId: wireId,
        action: 'edit',
        encryptedBody: encryptedPeer,
        modifiedAt: 2,
      );

      final sentModify = await service.syncDirectEditOutbound(
        targetMessageId: wireId,
        encryptedPeer: encryptedPeer,
        payload: payload,
      );

      expect(sentModify, isFalse);
      expect(postCalled, isFalse);
      final row = await PendingMessageDbHelper.getPendingOutboundForWireId(
        wireId,
      );
      expect(row!['message'], encryptedPeer);
    });

    test('attempts modify side-channel when nothing is pending', () async {
      const wireId = 'msg-2';
      var postCalled = false;
      MessageModifyService.postDirectOverride = ({
        required id,
        required encrypted,
        required timestamp,
        required peerId,
      }) async {
        postCalled = true;
        return false;
      };

      final service = MessageModifyService.direct(
        userId: 'me.onion',
        keyManager: keyManager,
        peerId: 'peer.onion',
      );
      final encryptedPeer = keyManager.encryptForPeer('edited', peerPublicKey);
      final payload = MessageModifyPayload(
        targetMessageId: wireId,
        action: 'edit',
        encryptedBody: encryptedPeer,
        modifiedAt: 2,
      );

      final sentModify = await service.syncDirectEditOutbound(
        targetMessageId: wireId,
        encryptedPeer: encryptedPeer,
        payload: payload,
      );

      expect(sentModify, isTrue);
      expect(postCalled, isTrue);
    });

    test('notifier delivers edit updates to listeners', () async {
      const wireId = 'msg-3';
      final captured = <MessageModifyUpdate>[];
      final sub = MessageModifyRefreshNotifier.instance.onModifyChanged.listen(
        captured.add,
      );
      addTearDown(sub.cancel);

      MessageModifyRefreshNotifier.instance.notify(
        MessageModifyUpdate(
          targetMessageId: wireId,
          action: 'edit',
          newText: 'edited',
          modifiedAt: 3,
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(captured, hasLength(1));
      expect(captured.first.newText, 'edited');
      expect(captured.first.targetMessageId, wireId);
    });
  });
}
