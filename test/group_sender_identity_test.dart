import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/crypto/group_crypto.dart';
import 'package:prysm/crypto/identity.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/peer_identity_loader.dart';
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

  group('loadGroupSenderIdentity', () {
    const localUserId = 'me.onion';
    const peerId = 'peer.onion';
    const groupId = 'group-1';

    late Database db;
    late KeyManager keyManager;

    setUp(() async {
      db = await _openTestDb();
      DBHelper.setDatabaseForTest(db);
      keyManager = KeyManager.fromIdentity(await IdentityKeyPair.generate());
      // The app stores a placeholder identity for the local user's own row.
      await DBHelper.insertOrUpdateUser({
        'id': localUserId,
        'name': 'me',
        'avatarUrl': '',
        'identityJson': 'NONE',
        'publicKeyPem': 'NONE',
      });
    });

    tearDown(() async {
      await db.close();
      DBHelper.setDatabaseForTest(null);
    });

    test('own group message decrypts despite placeholder identity row',
        () async {
      final groupKey = GroupCryptoV2.generateGroupKey();
      const plaintext = 'my own group message';
      final wire = await GroupCryptoV2.encryptWithSenderKey(
        epochKey: groupKey,
        groupId: groupId,
        senderId: localUserId,
        messageIndex: 1,
        plaintext: plaintext,
        sender: keyManager.identity,
      );

      final senderKeys = await loadGroupSenderIdentity(
        keyManager,
        localUserId,
        localUserId: localUserId,
      );
      expect(senderKeys, isNotNull);

      final decrypted = await GroupCryptoV2.decryptWithSenderKey(
        epochKey: groupKey,
        groupId: groupId,
        wire: wire,
        transportSenderId: localUserId,
        senderKeys: senderKeys!,
      );
      expect(decrypted, plaintext);
    });

    test('peer identity still resolves from the user store', () async {
      final peerIdentity = await IdentityKeyPair.generate();
      final peerPublicJson = await peerIdentity.toPublicJson();
      await DBHelper.insertOrUpdateUser({
        'id': peerId,
        'name': 'peer',
        'avatarUrl': '',
        'identityJson': jsonEncode(peerPublicJson),
      });

      final resolved = await loadGroupSenderIdentity(
        keyManager,
        peerId,
        localUserId: localUserId,
      );
      expect(resolved, isNotNull);
      expect(
        resolved!.signPublic.bytes,
        (await peerIdentity.signPublicKey).bytes,
      );
    });
  });
}
