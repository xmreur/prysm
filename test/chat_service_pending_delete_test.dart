import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/crypto/identity.dart';
import 'package:prysm/database/messages.dart';
import 'package:prysm/services/chat_service.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/pending_message_db_helper.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<Database> _openPendingDb() async {
  final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
  await db.execute('DROP TABLE IF EXISTS pending_messages');
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
  await db.execute('DROP TABLE IF EXISTS users');
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
  return db;
}

Future<Database> _openMessagesDb() async {
  final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
  await db.execute('DROP TABLE IF EXISTS messages');
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
      editedAt INTEGER
    )
  ''');
  return db;
}

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database pendingDb;
  late Database dbHelperDb;
  late Database messagesDb;
  late KeyManager keyManager;
  late IdentityKeyPair peerIdentity;

  setUp(() async {
    pendingDb = await _openPendingDb();
    PendingMessageDbHelper.setDatabaseForTest(pendingDb);

    dbHelperDb = await _openDbHelperDb();
    DBHelper.setDatabaseForTest(dbHelperDb);

    messagesDb = await _openMessagesDb();
    MessagesDb.setDatabaseForTest(messagesDb);

    peerIdentity = await IdentityKeyPair.generate();
    keyManager = KeyManager.fromIdentity(await IdentityKeyPair.generate());

    final identityJson = jsonEncode(await peerIdentity.toPublicJson());
    await DBHelper.insertOrUpdateUser({
      'id': 'peer.onion',
      'name': 'Peer',
      'identityJson': identityJson,
      'publicKeyPem': identityJson,
    });
  });

  tearDown(() async {
    await pendingDb.close();
    PendingMessageDbHelper.setDatabaseForTest(null);

    await dbHelperDb.close();
    DBHelper.setDatabaseForTest(null);

    await messagesDb.close();
    MessagesDb.setDatabaseForTest(null);
  });

  test('processPendingForPeer removes deleted messages from queue', () async {
    const wireId = 'msg-1';
    const senderId = 'me.onion';
    const receiverId = 'peer.onion';

    await MessagesDb.insertMessage({
      'id': wireId,
      'senderId': senderId,
      'receiverId': receiverId,
      'message': 'self-cipher',
      'type': 'text',
      'status': 'pending',
      'timestamp': 1,
    });

    await PendingMessageDbHelper.insertPendingMessage({
      'id': wireId,
      'senderId': senderId,
      'receiverId': receiverId,
      'message': 'peer-cipher',
      'type': 'text',
      'timestamp': 1,
      'status': 'pending',
    });

    await MessagesDb.deleteMessageById(wireId);

    await ChatService.processPendingForPeer(
      userId: senderId,
      peerId: receiverId,
      keyManager: keyManager,
    );

    final remaining = await PendingMessageDbHelper.getPendingMessages(
      receiverId: receiverId,
    );
    expect(remaining, isEmpty);
  });
}
