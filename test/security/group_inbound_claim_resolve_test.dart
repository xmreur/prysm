// CR6: the inbound group claim resolve sits outside the try/catch that
// guards the store. A throw in the resolve (e.g. the group_inbound_seen
// table vanishing under the UPDATE) escaped _handleChatMessage, and
// PrysmServer turned it into a 500 for a message that was already stored —
// leaving the claim row unresolved forever.
//
// RED/GREEN: pre-fix the router call itself fails (the resolve's throw
// escapes); post-fix it answers the normal success ack and the message row
// exists. The retry of the same envelope stays refused while this process
// lives (the claim key survives the failed resolve), so a replay can never
// be stored a second time — only a restart's takeover path could ever
// re-deliver it, and the floor refuses the index below it regardless.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/constants/group_constants.dart';
import 'package:prysm/crypto/crypto.dart';
import 'package:prysm/database/messages.dart';
import 'package:prysm/server/inbound_message_router.dart';
import 'package:prysm/services/settings_service.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/util/group_sender_index_store.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Hand-written fake `Database` over the messages seam: every member
/// delegates to the real messages database, except that the first `insert`
/// into `messages` — the store of the inbound message — is followed by
/// dropping `group_inbound_seen` on the DBHelper database. That is exactly
/// the failure surface the resolve step must survive: the message row is
/// already stored when the resolve's `UPDATE group_inbound_seen` dies on a
/// missing table, with a genuine DatabaseException from the storage layer
/// (the same surface a disk failure produces). No monkey-patching of the
/// router or the store.
class _DropSeenTableAfterStoreDatabase implements Database {
  _DropSeenTableAfterStoreDatabase(this._inner, this._dbHelperDb);

  final Database _inner;
  final Database _dbHelperDb;
  bool _dropped = false;

  @override
  Future<int> insert(
    String table,
    Map<String, Object?> values, {
    String? nullColumnHack,
    ConflictAlgorithm? conflictAlgorithm,
  }) async {
    final result = await _inner.insert(
      table,
      values,
      nullColumnHack: nullColumnHack,
      conflictAlgorithm: conflictAlgorithm,
    );
    if (!_dropped && table == 'messages') {
      _dropped = true;
      // The inbound message row is stored at this point; the claim's table
      // now vanishes underneath the resolve step.
      await _dbHelperDb.execute('DROP TABLE group_inbound_seen');
    }
    return result;
  }

  @override
  String get path => _inner.path;

  @override
  bool get isOpen => _inner.isOpen;

  @override
  Database get database => this;

  @override
  Batch batch() => _inner.batch();

  @override
  Future<void> close() => _inner.close();

  @override
  Future<int> delete(
    String table, {
    String? where,
    List<Object?>? whereArgs,
  }) =>
      _inner.delete(table, where: where, whereArgs: whereArgs);

  @override
  Future<T> devInvokeMethod<T>(String method, [Object? arguments]) =>
      // ignore: deprecated_member_use
      _inner.devInvokeMethod<T>(method, arguments);

  @override
  Future<T> devInvokeSqlMethod<T>(
    String method,
    String sql, [
    List<Object?>? arguments,
  ]) =>
      // ignore: deprecated_member_use
      _inner.devInvokeSqlMethod<T>(method, sql, arguments);

  @override
  Future<void> execute(String sql, [List<Object?>? arguments]) =>
      _inner.execute(sql, arguments);

  @override
  Future<List<Map<String, Object?>>> query(
    String table, {
    bool? distinct,
    List<String>? columns,
    String? where,
    List<Object?>? whereArgs,
    String? groupBy,
    String? having,
    String? orderBy,
    int? limit,
    int? offset,
  }) =>
      _inner.query(
        table,
        distinct: distinct,
        columns: columns,
        where: where,
        whereArgs: whereArgs,
        groupBy: groupBy,
        having: having,
        orderBy: orderBy,
        limit: limit,
        offset: offset,
      );

  @override
  Future<QueryCursor> queryCursor(
    String table, {
    bool? distinct,
    List<String>? columns,
    String? where,
    List<Object?>? whereArgs,
    String? groupBy,
    String? having,
    String? orderBy,
    int? limit,
    int? offset,
    int? bufferSize,
  }) =>
      _inner.queryCursor(
        table,
        distinct: distinct,
        columns: columns,
        where: where,
        whereArgs: whereArgs,
        groupBy: groupBy,
        having: having,
        orderBy: orderBy,
        limit: limit,
        offset: offset,
        bufferSize: bufferSize,
      );

  @override
  Future<int> rawDelete(String sql, [List<Object?>? arguments]) =>
      _inner.rawDelete(sql, arguments);

  @override
  Future<int> rawInsert(String sql, [List<Object?>? arguments]) =>
      _inner.rawInsert(sql, arguments);

  @override
  Future<List<Map<String, Object?>>> rawQuery(
    String sql, [
    List<Object?>? arguments,
  ]) =>
      _inner.rawQuery(sql, arguments);

  @override
  Future<QueryCursor> rawQueryCursor(
    String sql,
    List<Object?>? arguments, {
    int? bufferSize,
  }) =>
      _inner.rawQueryCursor(sql, arguments, bufferSize: bufferSize);

  @override
  Future<int> rawUpdate(String sql, [List<Object?>? arguments]) =>
      _inner.rawUpdate(sql, arguments);

  @override
  Future<T> readTransaction<T>(Future<T> Function(Transaction txn) action) =>
      _inner.readTransaction(action);

  @override
  Future<T> transaction<T>(
    Future<T> Function(Transaction txn) action, {
    bool? exclusive,
  }) =>
      _inner.transaction(action, exclusive: exclusive);

  @override
  Future<int> update(
    String table,
    Map<String, Object?> values, {
    String? where,
    List<Object?>? whereArgs,
    ConflictAlgorithm? conflictAlgorithm,
  }) =>
      _inner.update(
        table,
        values,
        where: where,
        whereArgs: whereArgs,
        conflictAlgorithm: conflictAlgorithm,
      );
}

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

Future<void> _createMessagesTable(Database db) async {
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
}

Future<Database> _openMessagesDb() async {
  final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
  await _createMessagesTable(db);
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
  await RatchetSessionStore.ensureTable(db);
  await GroupSenderIndexStore.ensureTable(db);
  return db;
}

/// Builds a group chat message whose `message` field is a signed group
/// sender-key envelope with the given [index].
Future<Map<String, dynamic>> _groupMessage({
  required String id,
  required IdentityKeyPair sender,
  required String senderId,
  required String groupId,
  required int index,
  int timestamp = 1000,
}) async {
  final wire = await GroupCryptoV2.encryptWithSenderKey(
    epochKey: Uint8List.fromList(List.generate(32, (i) => i)),
    groupId: groupId,
    senderId: senderId,
    messageIndex: index,
    plaintext: 'hello-$index',
    sender: sender,
  );
  return {
    'id': id,
    'senderId': senderId,
    'receiverId': 'local.onion',
    'message': wire,
    'type': groupTextType,
    'groupId': groupId,
    'timestamp': timestamp,
  };
}

void main() {
  late Directory docsDir;
  late Database messagesDb;
  late Database dbHelperDb;
  late InboundMessageRouter router;
  late IdentityKeyPair alice;
  late Map<String, IdentityPublicKeys> peers;

  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;

    // insertInboundMessage unconditionally probes MessageBlobStore, which
    // shells out to path_provider even when no blob file exists.
    docsDir = Directory.systemTemp.createTempSync(
      'group_inbound_claim_resolve_test',
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
    alice = await IdentityKeyPair.generate();
    peers = {'alice.onion': await _publicKeys(alice)};

    messagesDb = await _openMessagesDb();
    MessagesDb.setDatabaseForTest(messagesDb);

    dbHelperDb = await _openDbHelperDb();
    DBHelper.setDatabaseForTest(dbHelperDb);
    // The anti-replay gate resolves the sender cache-only
    // (loadPeerIdentityFromDb), so the member must be in the local user
    // store for the signature to verify.
    await DBHelper.insertOrUpdateUser({
      'id': 'alice.onion',
      'name': 'Alice',
      'identityJson': jsonEncode(await alice.toPublicJson()),
      'publicKeyPem': jsonEncode(await alice.toPublicJson()),
    });

    router = InboundMessageRouter(
      keyManager: KeyManager(),
      settings: SettingsService(),
      localOnionAddress: () => 'local.onion',
      resolvePeerIdentity: (senderId) async => peers[senderId],
    );
  });

  tearDown(() async {
    // Claim ownership is process-global: a claim left by one case would
    // refuse the same triple in the next, so it must be cleared between
    // cases.
    GroupSenderIndexStore.resetForTest();
    await messagesDb.close();
    MessagesDb.setDatabaseForTest(null);

    await dbHelperDb.close();
    DBHelper.setDatabaseForTest(null);
  });

  group('a failed claim resolve must not fail a stored delivery', () {
    test(
      'RED: a throw in the resolve step is contained — the router still '
      'acks the stored message (pre-fix: the resolve escaped the router '
      'and the delivery surfaced as a failure)', () async {
        // Honest fault injection with the real DAOs: the delegating
        // wrapper around the messages seam stores the message normally and
        // then drops the claim's table underneath the resolve step.
        MessagesDb.setDatabaseForTest(
          _DropSeenTableAfterStoreDatabase(messagesDb, dbHelperDb),
        );

        final result = await router.handleMessage(
          await _groupMessage(
            id: 'm1',
            sender: alice,
            senderId: 'alice.onion',
            groupId: 'g1',
            index: 0,
          ),
        );

        // The message is stored, so the delivery succeeded: the failed
        // resolve must not turn it into a 500 (pre-fix the throw escaped
        // _handleChatMessage and PrysmServer surfaced a 500 for a message
        // that was already stored).
        expect(result.statusCode, 200);
        expect(result.jsonBody?['status'], 'received');
        expect(result.jsonBody?['id'], 'm1');
        expect(result.jsonBody?['timestamp'], isA<int>());

        final rows = await messagesDb.query('messages');
        expect(rows, hasLength(1));
        expect(rows.single['id'], 'g1::m1');
      },
    );
  });
}
