import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/crypto/identity.dart';
import 'package:prysm/crypto/ratchet/session_store.dart';
import 'package:prysm/database/conversation_preferences_db.dart';
import 'package:prysm/database/message_schema_migrations.dart';
import 'package:prysm/database/messages.dart';
import 'package:prysm/l10n/app_localizations.dart';
import 'package:prysm/models/appearance_settings.dart';
import 'package:prysm/models/contact.dart';
import 'package:prysm/models/group.dart';
import 'package:prysm/models/locale_override.dart';
import 'package:prysm/screens/group_settings_screen.dart';
import 'package:prysm/theme/prysm_style_resolver.dart';
import 'package:prysm/theme/prysm_style_scope.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/locale_resolution.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> _pumpSettings(WidgetTester tester, Widget child) async {
  final locale = resolveLocale(LocaleOverride.en);
  await AppLocalizations.delegate.load(locale);
  await tester.pumpWidget(
    PrysmStyleScope(
      style: PrysmStyleResolver.resolve(
        themePalette: 0,
        appearance: const AppearanceSettings(),
      ),
      child: WidgetsApp(
        locale: locale,
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
        ],
        color: const Color(0xFF000000),
        pageRouteBuilder: <T>(RouteSettings settings, WidgetBuilder builder) =>
            PageRouteBuilder<T>(
              settings: settings,
              pageBuilder: (context, animation, secondaryAnimation) =>
                  builder(context),
            ),
        home: child,
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late Database chatDb;
  late Database messagesDb;
  late KeyManager keyManager;
  final l10n = lookupAppLocalizations(const Locale('en'));

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    tempDir = Directory.systemTemp.createTempSync('group_settings_screen_test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async {
        if (call.method == 'getApplicationDocumentsDirectory' ||
            call.method == 'getTemporaryDirectory') {
          return tempDir.path;
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
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    chatDb = await databaseFactory.openDatabase(
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
              createdAt INTEGER NOT NULL,
              onlyAdminsCanAdd INTEGER NOT NULL DEFAULT 1
            )
          ''');
          await db.execute('''
            CREATE TABLE group_members (
              groupId TEXT NOT NULL,
              memberId TEXT NOT NULL,
              role TEXT NOT NULL,
              joinedAt INTEGER NOT NULL,
              muted INTEGER NOT NULL DEFAULT 0,
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
          await ConversationPreferencesDb.createTable(db);
          await RatchetSessionStore.ensureTable(db);
        },
      ),
    );
    DBHelper.setDatabaseForTest(chatDb);

    messagesDb = await databaseFactory.openDatabase(
      '${inMemoryDatabasePath}_settings_msg',
      options: OpenDatabaseOptions(
        version: MessageSchemaMigrations.dbVersion,
        onCreate: MessageSchemaMigrations.onCreate,
      ),
    );
    MessagesDb.setDatabaseForTest(messagesDb);

    keyManager = KeyManager.fromIdentity(await IdentityKeyPair.generate());

    await chatDb.insert('groups', {
      'id': 'g1',
      'name': 'Squad',
      'createdBy': 'me.onion',
      'createdAt': 1,
      'onlyAdminsCanAdd': 1,
    });
    await chatDb.insert('group_members', {
      'groupId': 'g1',
      'memberId': 'me.onion',
      'role': 'owner',
      'joinedAt': 1,
      'muted': 0,
    });
    await chatDb.insert('group_members', {
      'groupId': 'g1',
      'memberId': 'alice.onion',
      'role': 'member',
      'joinedAt': 1,
      'muted': 0,
    });
  });

  tearDown(() async {
    DBHelper.setDatabaseForTest(null);
    MessagesDb.setDatabaseForTest(null);
    await chatDb.close();
    await messagesDb.close();
  });

  testWidgets('owner settings sheet offers mute and promote', (tester) async {
    await _pumpSettings(
      tester,
      GroupSettingsScreen(
        group: Group(
          id: 'g1',
          name: 'Squad',
          createdBy: 'me.onion',
          createdAt: 1,
        ),
        userId: 'me.onion',
        contacts: [
          Contact(
            id: 'alice.onion',
            name: 'Alice',
            avatarUrl: '',
            identityJson: '{}',
          ),
        ],
        keyManager: keyManager,
        onChanged: () {},
        onLeftOrDeleted: () {},
      ),
    );
    // sqflite FFI completes on the real event loop; FakeAsync + pumpAndSettle
    // never finishes because PrysmProgressIndicator.repeat() has no end.
    await tester.pump();
    for (var i = 0; i < 40; i++) {
      if (find.text(l10n.youAreOwner).evaluate().isNotEmpty) break;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }

    expect(find.text(l10n.youAreOwner), findsOneWidget);
    await tester.ensureVisible(find.text('Alice'));
    await tester.tap(find.text('Alice'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text(l10n.promoteToAdmin), findsOneWidget);
    expect(find.text(l10n.muteMember), findsOneWidget);

    // Child tiles (prefs / disappearing) still have in-flight sqlite queries
    // with 10s FakeAsync timeouts. Drain them before the tree is disposed.
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
