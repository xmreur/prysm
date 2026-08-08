import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/crypto/identity.dart';
import 'package:prysm/database/message_schema_migrations.dart';
import 'package:prysm/database/messages.dart';
import 'package:prysm/database/self_messages_db.dart';
import 'package:prysm/screens/widgets/linked_message_text.dart';
import 'package:prysm/services/self_chat_service.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> _openUrl(String url) async {}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
    await MessageSchemaMigrations.onCreate(db, MessageSchemaMigrations.dbVersion);
    MessagesDb.setDatabaseForTest(db);
    SelfMessagesDb.setDatabaseForTest(db);
  });

  tearDown(() async {
    await MessagesDb.close();
    MessagesDb.setDatabaseForTest(null);
    SelfMessagesDb.setDatabaseForTest(null);
  });

  testWidgets('LinkedMessageText scales with the ambient text scaler',
      (tester) async {
    Future<double> scaledFontSize(TextScaler scaler) async {
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(textScaler: scaler),
            child: const LinkedMessageText(
              text: 'hello world',
              textColor: Colors.black,
              fontSize: 14,
              onOpenUrl: _openUrl,
            ),
          ),
        ),
      );
      final paragraph = tester.renderObject<RenderParagraph>(
        find.descendant(
          of: find.byType(LinkedMessageText),
          matching: find.byType(RichText),
        ),
      );
      return paragraph.textScaler.scale(14);
    }

    expect(await scaledFontSize(TextScaler.linear(2.0)), 28.0);
    expect(await scaledFontSize(TextScaler.linear(1.0)), 14.0);
  });

  test('sendTextMessage stores the note even when the FTS table is missing',
      () async {
    final db = await MessagesDb.database;
    await db.execute('DROP TABLE message_search_fts');

    final keyManager =
        KeyManager.fromIdentity(await IdentityKeyPair.generate());
    final service = SelfChatService(userId: 'me.onion', keyManager: keyManager);

    final id = await service.sendTextMessage('hello world');

    expect(await SelfMessagesDb.getMessageById(id), hasLength(1));
  });
}
