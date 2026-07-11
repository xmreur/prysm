import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/crypto/identity.dart';
import 'package:prysm/database/messages.dart';
import 'package:prysm/services/chat_service.dart';
import 'package:prysm/util/key_manager.dart';
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
  return db;
}

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database messagesDb;

  setUp(() async {
    messagesDb = await _openMessagesDb();
    MessagesDb.setDatabaseForTest(messagesDb);
  });

  tearDown(() async {
    await messagesDb.close();
    MessagesDb.setDatabaseForTest(null);
  });

  test('onMessageInserted emits when a message is inserted', () async {
    final events = <Map<String, dynamic>>[];
    final sub = MessagesDb.onMessageInserted.listen(events.add);
    addTearDown(sub.cancel);

    await MessagesDb.insertMessage({
      'id': 'msg-1',
      'senderId': 'me.onion',
      'receiverId': 'peer.onion',
      'message': 'hello',
      'type': 'text',
      'timestamp': 1,
    });

    await Future<void>.delayed(Duration.zero);
    expect(events, hasLength(1));
    expect(events.first['id'], 'msg-1');
  });

  test('ChatService forwards local call messages to onNewMessages', () async {
    final service = ChatService(
      userId: 'me.onion',
      peerId: 'peer.onion',
      keyManager: KeyManager.fromIdentity(await IdentityKeyPair.generate()),
    );
    service.startPolling();
    addTearDown(service.dispose);

    final received = <List<Map<String, dynamic>>>[];
    final sub = service.onNewMessages.listen(received.add);
    addTearDown(sub.cancel);

    final timestamp = DateTime.now().millisecondsSinceEpoch;
    await MessagesDb.insertMessage({
      'id': 'call-msg-1',
      'senderId': 'me.onion',
      'receiverId': 'peer.onion',
      'message': '{"durationMs":0,"status":"completed","direction":"outbound"}',
      'type': 'call',
      'timestamp': timestamp,
      'status': 'system',
    });

    await Future<void>.delayed(const Duration(milliseconds: 100));
    service.stopPolling();

    expect(received, hasLength(1));
    expect(received.first.first['id'], 'call-msg-1');
    expect(received.first.first['type'], 'call');
  });

  test('ChatService ignores local inserts for other peers', () async {
    final service = ChatService(
      userId: 'me.onion',
      peerId: 'peer.onion',
      keyManager: KeyManager.fromIdentity(await IdentityKeyPair.generate()),
    );
    service.startPolling();
    addTearDown(service.dispose);

    final received = <List<Map<String, dynamic>>>[];
    final sub = service.onNewMessages.listen(received.add);
    addTearDown(sub.cancel);

    await MessagesDb.insertMessage({
      'id': 'other-msg',
      'senderId': 'me.onion',
      'receiverId': 'other.onion',
      'message': 'hello',
      'type': 'text',
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });

    await Future<void>.delayed(const Duration(milliseconds: 100));
    service.stopPolling();

    expect(received, isEmpty);
  });
}
