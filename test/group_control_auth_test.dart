import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/constants/group_constants.dart';
import 'package:prysm/crypto/aead.dart';
import 'package:prysm/crypto/envelope.dart';
import 'package:prysm/crypto/group_crypto.dart';
import 'package:prysm/crypto/identity.dart';
import 'package:prysm/crypto/ratchet/session_store.dart';
import 'package:prysm/crypto/wire.dart';
import 'package:prysm/database/messages.dart';
import 'package:prysm/services/group_service.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/util/group_sender_index_store.dart';
import 'package:prysm/util/key_manager.dart';
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
        await db.execute('''
          CREATE TABLE messages (
            id TEXT PRIMARY KEY,
            senderId TEXT,
            receiverId TEXT,
            message TEXT,
            timestamp INTEGER,
            groupId TEXT
          )
        ''');
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

Future<void> _insertGroupWithMember(
  Database db, {
  required String groupId,
  required String createdBy,
  required List<String> memberIds,
}) async {
  await db.insert('groups', {
    'id': groupId,
    'name': 'Group $groupId',
    'createdBy': createdBy,
    'createdAt': 1000,
  });
  for (final memberId in memberIds) {
    await db.insert('group_members', {
      'groupId': groupId,
      'memberId': memberId,
      'role': memberId == createdBy ? 'admin' : 'member',
      'joinedAt': 1000,
    });
  }
}

/// Builds a legacy unsigned `control-wrap-1` envelope the way the pre-fix
/// encryptControlPayload did (ECDH key wrap without an Ed25519 signature).
Future<String> _legacyControlWrap1(
  String plaintextJson,
  IdentityKeyPair sender,
  IdentityKeyPair recipient,
) async {
  final sessionKey = GroupCryptoV2.generateGroupKey();
  final wrapped = await CryptoWire.wrapKeyForPeer(
    sessionKey,
    sender,
    await recipient.agreePublicKey,
  );
  final aeadKey = await CryptoAead.secretKeyFromBytes(sessionKey);
  final enc = await CryptoAead.encryptAesGcm(
    utf8.encode(plaintextJson),
    key: aeadKey,
  );
  return CryptoEnvelope.encode(CryptoEnvelope.controlWrap1(
    wrappedKey: wrapped,
    iv: enc.nonce,
    ciphertext: enc.ciphertext,
  ));
}

Future<String> _keyRotatePayload(
  IdentityKeyPair sender,
  IdentityKeyPair recipient, {
  required String groupId,
  required int keyVersion,
}) async {
  final newKey = GroupCryptoV2.generateGroupKey();
  final encryptedGroupKey = await GroupCryptoV2.encryptGroupKeyForStorage(
    newKey,
    sender,
    peerAgreePublic: await recipient.agreePublicKey,
  );
  return jsonEncode({
    'groupId': groupId,
    'encryptedGroupKey': encryptedGroupKey,
    'keyVersion': keyVersion,
  });
}

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('GroupCryptoV2 authenticated control payload', () {
    test('signed control-wrap-2 round trip', () async {
      final sender = await IdentityKeyPair.generate();
      final recipient = await IdentityKeyPair.generate();
      const plaintext = '{"groupId":"g1","keyVersion":2}';

      final wire = await GroupCryptoV2.encryptControlPayload(
        plaintext,
        sender,
        await recipient.agreePublicKey,
      );
      final envelope = CryptoEnvelope.tryParse(wire)!;
      expect(envelope['scheme'], 'control-wrap-2');

      final decrypted = await GroupCryptoV2.decryptControlPayload(
        wire,
        recipient,
        IdentityPublicKeys(
          signPublic: await sender.signPublicKey,
          agreePublic: await sender.agreePublicKey,
          fingerprint: (await sender.toPublicJson())['fingerprint'] as String,
        ),
      );
      expect(decrypted, plaintext);
    });

    test('legacy control-wrap-1 is rejected as unsigned', () async {
      final sender = await IdentityKeyPair.generate();
      final recipient = await IdentityKeyPair.generate();
      final wire = await _legacyControlWrap1(
        '{"groupId":"g1"}',
        sender,
        recipient,
      );
      final senderKeys = IdentityPublicKeys(
        signPublic: await sender.signPublicKey,
        agreePublic: await sender.agreePublicKey,
        fingerprint: (await sender.toPublicJson())['fingerprint'] as String,
      );

      await expectLater(
        GroupCryptoV2.decryptControlPayload(wire, recipient, senderKeys),
        throwsA(isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('Unsigned group control message rejected'),
        )),
      );
    });

    test('control-wrap-2 signed by another identity is rejected', () async {
      final realSender = await IdentityKeyPair.generate();
      final attacker = await IdentityKeyPair.generate();
      final recipient = await IdentityKeyPair.generate();

      final wire = await GroupCryptoV2.encryptControlPayload(
        '{"groupId":"g1"}',
        attacker,
        await recipient.agreePublicKey,
      );
      final realSenderKeys = IdentityPublicKeys(
        signPublic: await realSender.signPublicKey,
        agreePublic: await realSender.agreePublicKey,
        fingerprint:
            (await realSender.toPublicJson())['fingerprint'] as String,
      );

      await expectLater(
        GroupCryptoV2.decryptControlPayload(wire, recipient, realSenderKeys),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('GroupService authenticated inbound control messages', () {
    const localUserId = 'me.onion';
    const memberId = 'member.onion';
    const outsiderId = 'outsider.onion';
    const groupId = 'g1';

    late Database db;
    late KeyManager keyManager;
    late GroupService service;

    setUp(() async {
      db = await _openTestDb();
      DBHelper.setDatabaseForTest(db);
      MessagesDb.setDatabaseForTest(db);
      keyManager = KeyManager.fromIdentity(await IdentityKeyPair.generate());
      service = GroupService(userId: localUserId, keyManager: keyManager);

      await _insertGroupWithMember(
        db,
        groupId: groupId,
        createdBy: localUserId,
        memberIds: [localUserId, memberId],
      );
      final v1Key = GroupCryptoV2.generateGroupKey();
      final encryptedForSelf =
          await GroupCryptoV2.encryptGroupKeyForStorage(v1Key, keyManager.identity);
      await DBHelper.upsertGroupKey(
        groupId: groupId,
        encryptedKey: encryptedForSelf,
        keyVersion: 1,
      );
    });

    tearDown(() async {
      await db.close();
      DBHelper.setDatabaseForTest(null);
      MessagesDb.setDatabaseForTest(null);
    });

    test('valid signed keyRotate from a member is accepted and processed', () async {
      final sender = await IdentityKeyPair.generate();
      await _insertIdentity(db, memberId, sender);
      final newKey = GroupCryptoV2.generateGroupKey();
      final encryptedGroupKey = await GroupCryptoV2.encryptGroupKeyForStorage(
        newKey,
        sender,
        peerAgreePublic: await keyManager.identity.agreePublicKey,
      );
      final wire = await GroupCryptoV2.encryptControlPayload(
        jsonEncode({
          'groupId': groupId,
          'encryptedGroupKey': encryptedGroupKey,
          'keyVersion': 2,
        }),
        sender,
        await keyManager.identity.agreePublicKey,
      );

      await service.handleIncomingControlMessage(
        groupKeyRotateType,
        wire,
        memberId,
      );

      expect(await service.getDecryptedGroupKey(groupId), newKey);
      expect((await DBHelper.getGroupKey(groupId))!['keyVersion'], 2);
    });

    test('legacy control-wrap-1 keyRotate is dropped', () async {
      final sender = await IdentityKeyPair.generate();
      await _insertIdentity(db, memberId, sender);
      final wire = await _legacyControlWrap1(
        await _keyRotatePayload(
          sender,
          keyManager.identity,
          groupId: groupId,
          keyVersion: 2,
        ),
        sender,
        keyManager.identity,
      );

      await service.handleIncomingControlMessage(
        groupKeyRotateType,
        wire,
        memberId,
      );

      expect((await DBHelper.getGroupKey(groupId))!['keyVersion'], 1);
    });

    test('keyRotate signed by another identity is dropped', () async {
      final sender = await IdentityKeyPair.generate();
      final attacker = await IdentityKeyPair.generate();
      await _insertIdentity(db, memberId, sender);
      final wire = await GroupCryptoV2.encryptControlPayload(
        await _keyRotatePayload(
          attacker,
          keyManager.identity,
          groupId: groupId,
          keyVersion: 2,
        ),
        attacker,
        await keyManager.identity.agreePublicKey,
      );

      await service.handleIncomingControlMessage(
        groupKeyRotateType,
        wire,
        memberId,
      );

      expect((await DBHelper.getGroupKey(groupId))!['keyVersion'], 1);
    });

    test('keyRotate from a non-member is dropped', () async {
      final outsider = await IdentityKeyPair.generate();
      await _insertIdentity(db, outsiderId, outsider);
      final wire = await GroupCryptoV2.encryptControlPayload(
        await _keyRotatePayload(
          outsider,
          keyManager.identity,
          groupId: groupId,
          keyVersion: 2,
        ),
        outsider,
        await keyManager.identity.agreePublicKey,
      );

      await service.handleIncomingControlMessage(
        groupKeyRotateType,
        wire,
        outsiderId,
      );

      expect((await DBHelper.getGroupKey(groupId))!['keyVersion'], 1);
    });

    test('invite signed by a non-member is accepted (signature suffices)', () async {
      const inviterId = 'inviter.onion';
      final inviter = await IdentityKeyPair.generate();
      await _insertIdentity(db, inviterId, inviter);

      final groupKey = GroupCryptoV2.generateGroupKey();
      final encryptedGroupKey = await GroupCryptoV2.encryptGroupKeyForStorage(
        groupKey,
        inviter,
        peerAgreePublic: await keyManager.identity.agreePublicKey,
      );
      final wire = await GroupCryptoV2.encryptControlPayload(
        jsonEncode({
          'groupId': 'g9',
          'name': 'Invited Group',
          'createdBy': inviterId,
          'members': [
            {'id': localUserId, 'role': 'member'},
            {'id': inviterId, 'role': 'admin'},
          ],
          'encryptedGroupKey': encryptedGroupKey,
          'keyVersion': 1,
        }),
        inviter,
        await keyManager.identity.agreePublicKey,
      );

      await service.handleIncomingControlMessage(
        groupInviteType,
        wire,
        inviterId,
      );

      expect(await DBHelper.getGroupById('g9'), isNotNull);
      expect(await service.getDecryptedGroupKey('g9'), groupKey);
      expect(await DBHelper.isGroupMember('g9', localUserId), isTrue);
    });
  });
}
