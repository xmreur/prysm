// Fase 5B: characterizes ConversationListRepository, extracted from the
// direct DB/service calls inline in `_HomeScreenState.loadUsers`. Verifies
// each method is a faithful 1:1 delegation against an in-memory sqflite db
// (sqflite ffi), matching the existing MessagesDb/DBHelper/SelfMessagesDb
// characterization style (see test/messages_db_characterization_test.dart).
import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/app/conversation_list_repository.dart';
import 'package:prysm/database/conversation_preferences_db.dart';
import 'package:prysm/database/messages.dart';
import 'package:prysm/database/self_messages_db.dart';
import 'package:prysm/services/conversation_preferences_service.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

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
  await SelfMessagesDb.createTable(db);
  return db;
}

Future<Database> _openDbHelperDb() async {
  final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
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
    CREATE TABLE group_members (
      groupId TEXT NOT NULL,
      memberId TEXT NOT NULL,
      role TEXT NOT NULL,
      joinedAt INTEGER NOT NULL,
      PRIMARY KEY (groupId, memberId)
    )
  ''');
  await ConversationPreferencesDb.createTable(db);
  return db;
}

void main() {
  late Database messagesDb;
  late Database dbHelperDb;
  const repository = ConversationListRepository();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    messagesDb = await _openMessagesDb();
    MessagesDb.setDatabaseForTest(messagesDb);

    dbHelperDb = await _openDbHelperDb();
    DBHelper.setDatabaseForTest(dbHelperDb);
  });

  tearDown(() async {
    await messagesDb.close();
    MessagesDb.setDatabaseForTest(null);

    await dbHelperDb.close();
    DBHelper.setDatabaseForTest(null);
  });

  test('getUsers delegates to DBHelper.getUsers', () async {
    await dbHelperDb.insert('users', {
      'id': 'peer1',
      'name': 'Peer One',
      'avatarBase64': null,
      'customName': null,
      'publicKeyPem': null,
      'identityJson': 'ident',
    });

    final users = await repository.getUsers();
    expect(users, hasLength(1));
    expect(users.single['id'], 'peer1');
    expect(users.single['name'], 'Peer One');
    expect(await repository.getUsers(), await DBHelper.getUsers());
  });

  test(
    'getLastMessageTimestampsForAllUsers delegates to MessagesDb',
    () async {
      await MessagesDb.insertMessage({
        'id': 'm1',
        'senderId': 'me',
        'receiverId': 'peer1',
        'message': 'a',
        'type': 'text',
        'timestamp': 1000,
        'status': 'sent',
      });
      await MessagesDb.insertMessage({
        'id': 'm2',
        'senderId': 'peer1',
        'receiverId': 'me',
        'message': 'b',
        'type': 'text',
        'timestamp': 4000,
        'status': 'received',
      });

      final timestamps = await repository.getLastMessageTimestampsForAllUsers();
      expect(timestamps['peer1'], 4000);
      expect(
        timestamps,
        await MessagesDb.getLastMessageTimestampsForAllUsers(),
      );
    },
  );

  test('getLastMessagePreviews delegates to MessagesDb', () async {
    await MessagesDb.insertMessage({
      'id': 'm1',
      'senderId': 'me',
      'receiverId': 'peer1',
      'message': 'a',
      'type': 'image',
      'timestamp': 2000,
      'status': 'sent',
    });

    final previews = await repository.getLastMessagePreviews('me');
    expect(previews['peer1'], '📷 Photo');
    expect(previews, await MessagesDb.getLastMessagePreviews('me'));
  });

  test('getUnreadCounts delegates to MessagesDb', () async {
    await MessagesDb.insertMessage({
      'id': 'd1',
      'senderId': 'peer1',
      'receiverId': 'me',
      'message': 'a',
      'type': 'text',
      'timestamp': 1000,
      'status': 'received',
    });
    await MessagesDb.insertMessage({
      'id': 'd2',
      'senderId': 'peer1',
      'receiverId': 'me',
      'message': 'b',
      'type': 'text',
      'timestamp': 2000,
      'status': 'received',
    });

    final counts = await repository.getUnreadCounts('me');
    expect(counts['peer1'], 2);
    expect(counts, await MessagesDb.getUnreadCounts('me'));
  });

  test(
    'getConversationPreferences delegates to ConversationPreferencesService',
    () async {
      await ConversationPreferencesService.instance.pin('peer1');

      final prefs = await repository.getConversationPreferences();
      expect(prefs['peer1']?.isPinned, isTrue);
      expect(prefs, await ConversationPreferencesService.instance.getAll());
    },
  );

  test('getSelfChatLastTimestamp/getSelfChatLastPreview delegate to SelfMessagesDb', () async {
    await SelfMessagesDb.insertMessage({
      'id': 's1',
      'message': 'note to self',
      'type': 'image',
      'timestamp': 3000,
    });

    expect(await repository.getSelfChatLastTimestamp(), 3000);
    expect(await repository.getSelfChatLastPreview(), '📷 Photo');
    expect(
      await repository.getSelfChatLastTimestamp(),
      await SelfMessagesDb.getLastTimestamp(),
    );
    expect(
      await repository.getSelfChatLastPreview(),
      await SelfMessagesDb.getLastPreview(),
    );
  });
}
