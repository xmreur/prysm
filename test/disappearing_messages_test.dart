import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/database/conversation_preferences_db.dart';
import 'package:prysm/database/message_schema_migrations.dart';
import 'package:prysm/database/messages.dart';
import 'package:prysm/models/conversation_preferences.dart';
import 'package:prysm/models/disappearing_timer.dart';
import 'package:prysm/services/disappearing_message_purge_service.dart';
import 'package:prysm/services/disappearing_timer_service.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

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
  await MessageSchemaMigrations.createReactionsTable(db);
  await MessageSchemaMigrations.createReadReceiptsTable(db);
  return db;
}

Future<Database> _openPrefsDb() async {
  final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
  await ConversationPreferencesDb.createTable(db);
  return db;
}

void main() {
  late Directory docsDir;
  late Database messagesDb;
  late Database prefsDb;

  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    docsDir = Directory.systemTemp.createTempSync('disappearing_messages_test');
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

  setUp(() async {
    messagesDb = await _openMessagesDb();
    MessagesDb.setDatabaseForTest(messagesDb);
    prefsDb = await _openPrefsDb();
    DBHelper.setDatabaseForTest(prefsDb);
  });

  tearDown(() async {
    await messagesDb.close();
    MessagesDb.setDatabaseForTest(null);
    await prefsDb.close();
    DBHelper.setDatabaseForTest(null);
  });

  test('expiresAtForSend returns null when timer is off', () async {
    await ConversationPreferencesDb.upsert(
      const ConversationPreferences(conversationId: 'peer1'),
    );
    final expiresAt = await DisappearingTimerService.expiresAtForSend('peer1');
    expect(expiresAt, isNull);
  });

  test('expiresAtForSend computes from active timer', () async {
    await ConversationPreferencesDb.upsert(
      const ConversationPreferences(
        conversationId: 'peer1',
        disappearingTimerSeconds: 3600,
      ),
    );
    final at = DateTime.utc(2026, 1, 1, 12);
    final expiresAt = await DisappearingTimerService.expiresAtForSend(
      'peer1',
      at: at,
    );
    expect(expiresAt, at.add(const Duration(hours: 1)).millisecondsSinceEpoch);
  });

  test('getNextExpiresAt and purgeDue hard-delete expired rows', () async {
    final past = DateTime.now().subtract(const Duration(minutes: 1));
    final future = DateTime.now().add(const Duration(hours: 1));
    await MessagesDb.insertMessage({
      'id': 'expired1',
      'senderId': 'a',
      'receiverId': 'b',
      'message': 'cipher',
      'type': 'text',
      'timestamp': past.millisecondsSinceEpoch,
      'expiresAt': past.millisecondsSinceEpoch,
    });
    await MessagesDb.insertMessage({
      'id': 'live1',
      'senderId': 'a',
      'receiverId': 'b',
      'message': 'cipher',
      'type': 'text',
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'expiresAt': future.millisecondsSinceEpoch,
    });

    final next = await MessagesDb.getNextExpiresAt();
    expect(next, future.millisecondsSinceEpoch);

    final purged =
        await DisappearingMessagePurgeService.instance.purgeDue(now: DateTime.now());
    expect(purged, 1);

    final expiredRow = await MessagesDb.getMessageById('expired1');
    expect(expiredRow, isEmpty);

    final liveRow = await MessagesDb.getMessageById('live1');
    expect(liveRow.first['deletedAt'], isNull);
    expect(liveRow.first['message'], 'cipher');
  });

  test('DisappearingTimerPresets labels', () {
    expect(DisappearingTimerPresets.labelForSeconds(null), 'Off');
    expect(DisappearingTimerPresets.labelForSeconds(86400), '1 day');
    expect(DisappearingTimerPresets.shortLabelForSeconds(300), '5m');
  });
}
