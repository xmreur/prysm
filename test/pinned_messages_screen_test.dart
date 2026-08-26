import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/database/message_schema_migrations.dart';
import 'package:prysm/database/messages.dart';
import 'package:prysm/database/pinned_messages_db.dart';
import 'package:prysm/screens/pinned_messages_screen.dart';
import 'package:prysm/services/pinned_messages_service.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'pump_prysm_l10n.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Database db;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    db = await databaseFactory.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    await MessageSchemaMigrations.onCreate(
      db,
      MessageSchemaMigrations.dbVersion,
    );
    MessagesDb.setDatabaseForTest(db);
    PinnedMessagesDb.debugDatabase = db;

    await db.insert('messages', {
      'id': 'msg-1',
      'senderId': 'me.onion',
      'receiverId': 'peer.onion',
      'message': 'cipher',
      'type': 'file',
      'fileName': 'notes.txt',
      'timestamp': 1,
    });
    await PinnedMessagesService.pin(
      messageId: 'msg-1',
      conversationId: 'peer.onion',
      scope: PinnedMessagesDb.scopeDirect,
    );
  });

  tearDown(() async {
    PinnedMessagesDb.debugDatabase = null;
    MessagesDb.setDatabaseForTest(null);
    await db.close();
  });

  testWidgets('pinned list shows the pin and tap pops the message id',
      (tester) async {
    String? popped;
    await pumpWithPrysmL10n(
      tester,
      Builder(
        builder: (context) {
          return GestureDetector(
            onTap: () async {
              popped = await Navigator.of(context).push<String>(
                PageRouteBuilder<String>(
                  pageBuilder: (context, animation, secondaryAnimation) =>
                      PinnedMessagesScreen(
                    conversationId: 'peer.onion',
                    scope: PinnedMessagesDb.scopeDirect,
                    keyManager: KeyManager(),
                  ),
                ),
              );
            },
            child: const Text('open'),
          );
        },
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pump();
    for (var i = 0; i < 20 && find.text('notes.txt').evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }

    expect(find.text('notes.txt'), findsOneWidget);

    await tester.tap(find.text('notes.txt'));
    await tester.pumpAndSettle();

    expect(popped, 'msg-1');
  });
}
