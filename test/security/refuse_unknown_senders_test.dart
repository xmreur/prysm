import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/constants/group_constants.dart';
import 'package:prysm/database/blocked_users_db.dart';
import 'package:prysm/database/conversation_preferences_db.dart';
import 'package:prysm/database/message_schema_migrations.dart';
import 'package:prysm/database/messages.dart';
import 'package:prysm/server/inbound_message_router.dart';
import 'package:prysm/services/block_service.dart';
import 'package:prysm/services/settings_service.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Database dbHelperDb;
  late Database messagesDb;
  late SettingsService settings;
  late InboundMessageRouter router;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    dbHelperDb = await databaseFactory.openDatabase(
      '${inMemoryDatabasePath}_${DateTime.now().microsecondsSinceEpoch}',
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, _) async {
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
          await BlockedUsersDb.createTable(db);
        },
      ),
    );
    DBHelper.setDatabaseForTest(dbHelperDb);
    await BlockService.instance.init();

    messagesDb = await databaseFactory.openDatabase(
      '${inMemoryDatabasePath}_${DateTime.now().microsecondsSinceEpoch}',
      options: OpenDatabaseOptions(
        version: MessageSchemaMigrations.dbVersion,
        onCreate: MessageSchemaMigrations.onCreate,
      ),
    );
    MessagesDb.setDatabaseForTest(messagesDb);

    SharedPreferences.setMockInitialValues({});
    settings = SettingsService();
    await settings.init();

    router = InboundMessageRouter(
      keyManager: KeyManager(),
      settings: settings,
      localOnionAddress: () => 'local.onion',
    );
  });

  tearDown(() async {
    DBHelper.setDatabaseForTest(null);
    MessagesDb.setDatabaseForTest(null);
    await dbHelperDb.close();
    await messagesDb.close();
  });

  Future<int> messageRowCount() async =>
      (await messagesDb.query('messages')).length;

  test(
    'setting on: unknown-sender DM is acked and dropped, no users row',
    () async {
      await settings.setRefuseUnknownSenders(true);
      addTearDown(() => settings.setRefuseUnknownSenders(false));

      final result = await router.processMessage({
        'id': 'msg-t1',
        'senderId': 'stranger.onion',
        'receiverId': 'local.onion',
        'message': 'cipher',
        'type': 'text',
        'timestamp': 1,
      });

      // A fake 200 leaks nothing and stops the sender's retry storm.
      expect(result.statusCode, 200);
      expect(await messageRowCount(), 0);
      expect(await DBHelper.getUserById('stranger.onion'), isNull);
    },
  );

  test(
    'setting off: first-contact DM from an unknown sender is stored',
    () async {
      // Default-off setting untouched: the first-contact flow keeps working.
      final result = await router.processMessage({
        'id': 'msg-t2',
        'senderId': 'firstcontact.onion',
        'receiverId': 'local.onion',
        'message': 'cipher',
        'type': 'text',
        'timestamp': 1,
      });

      expect(result.statusCode, 200);
      expect(await messageRowCount(), 1);
      // ensureUserExist creates the Unknown-xxxxxx contact row as before.
      expect(await DBHelper.getUserById('firstcontact.onion'), isNotNull);
    },
  );

  test(
    'setting on: DM from a sender with a users row is stored',
    () async {
      await dbHelperDb.insert('users', {'id': 'alice.onion', 'name': 'Alice'});
      await settings.setRefuseUnknownSenders(true);
      addTearDown(() => settings.setRefuseUnknownSenders(false));

      final result = await router.processMessage({
        'id': 'msg-t3',
        'senderId': 'alice.onion',
        'receiverId': 'local.onion',
        'message': 'cipher',
        'type': 'text',
        'timestamp': 1,
      });

      expect(result.statusCode, 200);
      expect(await messageRowCount(), 1);
    },
  );

  test(
    'blocked sender group message is acked and dropped (no groupId exemption)',
    () async {
      await BlockService.instance.block('blocked.onion');

      final result = await router.processMessage({
        'id': 'msg-t4',
        'senderId': 'blocked.onion',
        'receiverId': 'local.onion',
        'message': 'cipher',
        'type': groupTextType,
        'groupId': 'grp-1',
        'timestamp': 1,
      });

      expect(result.statusCode, 200);
      expect(await messageRowCount(), 0);
      expect(await DBHelper.getUserById('blocked.onion'), isNull);
    },
  );

  test(
    'group message from a sender who is not a member is acked and dropped: '
    'no users row, no message row (membership gate is independent of '
    'refuseUnknownSenders)',
    () async {
      final result = await router.processMessage({
        'id': 'msg-t6',
        'senderId': 'stranger.onion',
        'receiverId': 'local.onion',
        'message': 'cipher',
        'type': groupTextType,
        'groupId': 'grp-forged',
        'timestamp': 1,
      });

      expect(result.statusCode, 200);
      expect(result.jsonBody?['status'], 'received');
      expect(result.jsonBody?['id'], 'msg-t6');
      expect(await messageRowCount(), 0);
      expect(await DBHelper.getUserById('stranger.onion'), isNull);
    },
  );

  test(
    'group message from a member of the group is stored',
    () async {
      await dbHelperDb.insert('group_members', {
        'groupId': 'grp-1',
        'memberId': 'alice.onion',
        'role': 'member',
        'joinedAt': 0,
      });

      final result = await router.processMessage({
        'id': 'msg-t7',
        'senderId': 'alice.onion',
        'receiverId': 'local.onion',
        'message': 'cipher',
        'type': groupTextType,
        'groupId': 'grp-1',
        'timestamp': 1,
      });

      expect(result.statusCode, 200);
      expect(result.jsonBody?['status'], 'received');
      expect(await messageRowCount(), 1);
    },
  );

  test(
    'a forged groupId on a direct type is rejected, not treated as group traffic',
    () async {
      Map<String, dynamic> forged(String id) => {
        'id': id,
        'senderId': 'stranger.onion',
        'receiverId': 'local.onion',
        'message': 'cipher',
        'type': 'text',
        'groupId': 'grp-forged',
        'timestamp': 1,
      };

      // With the setting on, `groupId` would otherwise skip the gate entirely.
      await settings.setRefuseUnknownSenders(true);
      addTearDown(() => settings.setRefuseUnknownSenders(false));
      final refused = await router.handleMessage(forged('msg-t5-on'));
      expect(refused.statusCode, 400);

      // And with it off, the same payload would have skipped DirectMessageAuth,
      // which only runs when `groupId == null`.
      await settings.setRefuseUnknownSenders(false);
      final unsigned = await router.handleMessage(forged('msg-t5-off'));
      expect(unsigned.statusCode, 400);

      expect(await messageRowCount(), 0);
      expect(await DBHelper.getUserById('stranger.onion'), isNull);
    },
  );
}
