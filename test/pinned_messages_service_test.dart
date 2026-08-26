import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/database/message_schema_migrations.dart';
import 'package:prysm/database/messages.dart';
import 'package:prysm/database/pinned_messages_db.dart';
import 'package:prysm/services/pinned_messages_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Database db;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final tempDir = Directory.systemTemp.createTempSync('prysm_pinned_svc_');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => tempDir.path);
  });

  setUp(() async {
    db = await databaseFactory.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    await MessageSchemaMigrations.onCreate(db, MessageSchemaMigrations.dbVersion);
    MessagesDb.setDatabaseForTest(db);
    PinnedMessagesDb.debugDatabase = db;
  });

  tearDown(() async {
    PinnedMessagesDb.debugDatabase = null;
    MessagesDb.setDatabaseForTest(null);
    await db.close();
  });

  Future<void> insertDirect({
    required String id,
    int deletedAt = 0,
    String? message,
  }) {
    return db.insert('messages', {
      'id': id,
      'senderId': 'me.onion',
      'receiverId': 'peer.onion',
      'message': message ?? 'cipher',
      'type': 'text',
      'timestamp': 1,
      if (deletedAt > 0) 'deletedAt': deletedAt,
    });
  }

  test('pin is idempotent and round-trips', () async {
    await insertDirect(id: 'msg-1');
    await PinnedMessagesService.pin(
      messageId: 'msg-1',
      conversationId: 'peer.onion',
      scope: PinnedMessagesDb.scopeDirect,
    );
    await PinnedMessagesService.pin(
      messageId: 'msg-1',
      conversationId: 'peer.onion',
      scope: PinnedMessagesDb.scopeDirect,
    );

    expect(
      await PinnedMessagesService.isPinned(
        messageId: 'msg-1',
        conversationId: 'peer.onion',
        scope: PinnedMessagesDb.scopeDirect,
      ),
      isTrue,
    );
    final ids = await PinnedMessagesService.pinnedIdsForConversation(
      conversationId: 'peer.onion',
      scope: PinnedMessagesDb.scopeDirect,
    );
    expect(ids, {'msg-1'});
  });

  test('unpin removes the pin', () async {
    await insertDirect(id: 'msg-1');
    await PinnedMessagesService.pin(
      messageId: 'msg-1',
      conversationId: 'peer.onion',
      scope: PinnedMessagesDb.scopeDirect,
    );
    await PinnedMessagesService.unpin(
      messageId: 'msg-1',
      conversationId: 'peer.onion',
      scope: PinnedMessagesDb.scopeDirect,
    );
    expect(
      await PinnedMessagesService.pinnedIdsForConversation(
        conversationId: 'peer.onion',
        scope: PinnedMessagesDb.scopeDirect,
      ),
      isEmpty,
    );
  });

  test('listPinned excludes soft-deleted messages', () async {
    await insertDirect(id: 'live');
    await insertDirect(id: 'gone', deletedAt: 1, message: null);
    await PinnedMessagesService.pin(
      messageId: 'live',
      conversationId: 'peer.onion',
      scope: PinnedMessagesDb.scopeDirect,
    );
    await PinnedMessagesService.pin(
      messageId: 'gone',
      conversationId: 'peer.onion',
      scope: PinnedMessagesDb.scopeDirect,
    );

    final rows = await PinnedMessagesService.listPinned(
      conversationId: 'peer.onion',
      scope: PinnedMessagesDb.scopeDirect,
    );
    expect(rows.map((r) => r.messageId), ['live']);
  });

  test('hardDeleteMessage drops the pin row', () async {
    await insertDirect(id: 'msg-1');
    await PinnedMessagesService.pin(
      messageId: 'msg-1',
      conversationId: 'peer.onion',
      scope: PinnedMessagesDb.scopeDirect,
    );
    await MessagesDb.hardDeleteMessage('msg-1');
    expect(
      await PinnedMessagesService.pinnedIdsForConversation(
        conversationId: 'peer.onion',
        scope: PinnedMessagesDb.scopeDirect,
      ),
      isEmpty,
    );
  });
}
