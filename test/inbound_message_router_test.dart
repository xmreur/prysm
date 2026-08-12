import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/constants/group_constants.dart';
import 'package:prysm/crypto/crypto.dart';
import 'package:prysm/database/message_schema_migrations.dart';
import 'package:prysm/database/messages.dart';
import 'package:prysm/server/inbound_message_router.dart';
import 'package:prysm/services/disappearing_timer_service.dart';
import 'package:prysm/services/settings_service.dart';
import 'package:prysm/util/conversation_refresh_notifier.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<IdentityPublicKeys> _publicKeys(IdentityKeyPair id) async {
  final sign = await id.signPublicKey;
  final agree = await id.agreePublicKey;
  return IdentityPublicKeys(
    signPublic: sign,
    agreePublic: agree,
    fingerprint: IdentityKeyPair.fingerprintFromPublicJson(
      await id.toPublicJson(),
    ),
  );
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
      editedAt INTEGER,
      expiresAt INTEGER
    )
  ''');
  await MessageSchemaMigrations.createMessageSearchFtsTable(db);
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
    CREATE TABLE conversation_preferences (
      conversationId TEXT PRIMARY KEY,
      isPinned INTEGER NOT NULL DEFAULT 0,
      pinnedAt INTEGER,
      isArchived INTEGER NOT NULL DEFAULT 0,
      archivedAt INTEGER,
      disappearingTimerSeconds INTEGER
    )
  ''');
  // setDatabaseForTest wires RatchetService to this db; the send-side
  // encryptForPeer probes the session store before falling back to the
  // signed DM scheme.
  await RatchetSessionStore.ensureTable(db);
  return db;
}

void main() {
  test('InboundHandleResult helpers set status codes', () {
    final ok = InboundHandleResult.ok({'status': 'received'});
    expect(ok.statusCode, 200);
    expect(ok.jsonBody?['status'], 'received');

    final bad = InboundHandleResult.badRequest('invalid');
    expect(bad.statusCode, 400);
    expect(bad.jsonBody?['error'], 'invalid');

    final forbidden = InboundHandleResult.forbidden('nope');
    expect(forbidden.statusCode, 403);
  });

  group('inbound disappearing timer refresh', () {
    late Directory docsDir;
    late Database messagesDb;
    late Database dbHelperDb;
    late InboundMessageRouter router;
    late IdentityKeyPair local;
    late IdentityKeyPair alice;
    late IdentityPublicKeys localPublic;

    setUpAll(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;

      // The messages facade probes MessageBlobStore (path_provider) when it
      // stores payloads, so point the platform channel at a temp dir like
      // the other router suites do.
      docsDir = Directory.systemTemp.createTempSync(
        'inbound_message_router_timer_test',
      );
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
      local = await IdentityKeyPair.generate();
      alice = await IdentityKeyPair.generate();
      localPublic = await _publicKeys(local);

      messagesDb = await _openMessagesDb();
      MessagesDb.setDatabaseForTest(messagesDb);

      dbHelperDb = await _openDbHelperDb();
      DBHelper.setDatabaseForTest(dbHelperDb);
      // applyInboundDirect resolves the sender cache-only
      // (loadPeerIdentityFromDb), so alice must be in the local user store
      // with her identity for the signed envelope to verify.
      await DBHelper.insertOrUpdateUser({
        'id': 'alice.onion',
        'name': 'Alice',
        'identityJson': jsonEncode(await alice.toPublicJson()),
        'publicKeyPem': jsonEncode(await alice.toPublicJson()),
      });

      router = InboundMessageRouter(
        keyManager: KeyManager.fromIdentity(local),
        settings: SettingsService(),
        localOnionAddress: () => 'local.onion',
      );
    });

    tearDown(() async {
      await messagesDb.close();
      MessagesDb.setDatabaseForTest(null);

      await dbHelperDb.close();
      DBHelper.setDatabaseForTest(null);
    });

    /// Builds the direct disappearing-timer envelope exactly as the sender's
    /// DisappearingTimerService._broadcastDirect does: alice's identity
    /// encrypts the payload for the local peer.
    Future<Map<String, dynamic>> timerMessage({
      required String id,
      required int? timerSeconds,
      required int updatedAt,
    }) async {
      final aliceKm = KeyManager.fromIdentity(alice);
      final wire = await aliceKm.encryptForPeer(
        DisappearingTimerPayload(
          timerSeconds: timerSeconds,
          updatedAt: updatedAt,
        ).encode(),
        localPublic,
        peerId: 'local.onion',
      );
      return {
        'id': id,
        'senderId': 'alice.onion',
        'receiverId': 'local.onion',
        'message': wire,
        'type': disappearingTimerType,
        'timestamp': updatedAt,
      };
    }

    test(
      'an inbound disappearing-timer message that applies fires the '
      'conversation refresh notifier', () async {
        var refreshCount = 0;
        final sub = ConversationRefreshNotifier.instance.onRefresh.listen((_) {
          refreshCount++;
        });
        addTearDown(sub.cancel);

        final result = await router.handleMessage(
          await timerMessage(
            id: 'dt-1',
            timerSeconds: 3600,
            updatedAt: 5000,
          ),
        );

        expect(result.statusCode, 200);
        expect(result.jsonBody?['status'], 'received');
        // The timer notice row the chat screen renders landed too: this is
        // what makes the stale sidebar observable. The awaited query also
        // yields to the event loop so the refresh notification's delivery
        // microtask runs before the assertions (same pattern as the
        // contact-add refresh characterization test).
        final rows = await messagesDb.query('messages');
        expect(rows, hasLength(1));
        expect(rows.single['type'], disappearingTimerNoticeType);
        expect(refreshCount, 1);
      },
    );

    test(
      'an inbound disappearing-timer message whose apply fails returns 500 '
      'and does not fire the conversation refresh notifier', () async {
        var refreshCount = 0;
        final sub = ConversationRefreshNotifier.instance.onRefresh.listen((_) {
          refreshCount++;
        });
        addTearDown(sub.cancel);

        // Honest fault injection: dropping the conversation_preferences table
        // makes _applyInboundIfNewer throw a genuine DatabaseException from
        // the storage layer (same technique as the group anti-replay suite).
        await dbHelperDb.execute('DROP TABLE conversation_preferences');

        final result = await router.handleMessage(
          await timerMessage(
            id: 'dt-2',
            timerSeconds: 3600,
            updatedAt: 5000,
          ),
        );

        expect(result.statusCode, 500);
        // No timer notice landed and, once the microtask queue drains, no
        // refresh fired either: the failed apply must leave the sidebar
        // alone. The awaited query flushes the delivery microtask so a
        // regression (notify on failure) would be caught here.
        final rows = await messagesDb.query('messages');
        expect(rows, isEmpty);
        expect(refreshCount, 0);
      },
    );
  });
}
