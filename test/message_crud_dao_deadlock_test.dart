// Task 9 finding 2 (Low): getMessageById must not re-enter the messages
// mutex from inside its own critical section. Pre-fix, the wire-read
// fallback called getMessageWire, which re-acquires the (non-reentrant)
// MessagesDatabase.mutex, deadlocking the caller instead of returning.
// This test forces the rare wire-read failure with a hand-written fake
// Database and proves the call completes instead of hanging.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/database/messages_database.dart';
import 'package:prysm/database/messages.dart';
import 'package:sqflite/sqflite.dart';

/// Hand-written fake `Database`: the first `query` (the metadata read inside
/// getMessageById) succeeds; every later read throws, forcing the fallback
/// migration branch that used to deadlock by re-entering the mutex.
class _FailingWireReadDatabase implements Database {
  int _queryCount = 0;

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
  }) async {
    _queryCount++;
    if (_queryCount == 1) {
      return [
        {
          'id': 'm1',
          'senderId': 'alice',
          'receiverId': 'bob',
          'message': 'stale-meta',
          'timestamp': 1,
        },
      ];
    }
    throw StateError('simulated wire read failure');
  }

  @override
  String get path => throw UnimplementedError();

  @override
  bool get isOpen => throw UnimplementedError();

  @override
  Database get database => this;

  @override
  Batch batch() => throw UnimplementedError();

  @override
  Future<void> close() => throw UnimplementedError();

  @override
  Future<int> delete(String table, {String? where, List<Object?>? whereArgs}) =>
      throw UnimplementedError();

  @override
  Future<T> devInvokeMethod<T>(String method, [Object? arguments]) =>
      throw UnimplementedError();

  @override
  Future<T> devInvokeSqlMethod<T>(
    String method,
    String sql, [
    List<Object?>? arguments,
  ]) =>
      throw UnimplementedError();

  @override
  Future<void> execute(String sql, [List<Object?>? arguments]) =>
      throw UnimplementedError();

  @override
  Future<int> insert(
    String table,
    Map<String, Object?> values, {
    String? nullColumnHack,
    ConflictAlgorithm? conflictAlgorithm,
  }) =>
      throw UnimplementedError();

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
      throw UnimplementedError();

  @override
  Future<int> rawDelete(String sql, [List<Object?>? arguments]) =>
      throw UnimplementedError();

  @override
  Future<int> rawInsert(String sql, [List<Object?>? arguments]) =>
      throw UnimplementedError();

  @override
  Future<List<Map<String, Object?>>> rawQuery(
    String sql, [
    List<Object?>? arguments,
  ]) =>
      throw UnimplementedError();

  @override
  Future<QueryCursor> rawQueryCursor(
    String sql,
    List<Object?>? arguments, {
    int? bufferSize,
  }) =>
      throw UnimplementedError();

  @override
  Future<int> rawUpdate(String sql, [List<Object?>? arguments]) =>
      throw UnimplementedError();

  @override
  Future<T> readTransaction<T>(
    Future<T> Function(Transaction txn) action,
  ) =>
      throw UnimplementedError();

  @override
  Future<T> transaction<T>(
    Future<T> Function(Transaction txn) action, {
    bool? exclusive,
  }) =>
      throw UnimplementedError();

  @override
  Future<int> update(
    String table,
    Map<String, Object?> values, {
    String? where,
    List<Object?>? whereArgs,
    ConflictAlgorithm? conflictAlgorithm,
  }) =>
      throw UnimplementedError();
}

void main() {
  late Directory docsDir;

  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();

    // getMessageById/getMessageWire unconditionally probe MessageBlobStore,
    // which shells out to path_provider even when no blob file exists.
    docsDir = Directory.systemTemp.createTempSync('message_crud_dao_deadlock');
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

  tearDown(() {
    MessagesDatabase.setDatabaseForTest(null);
  });

  test('getMessageById completes via the fallback instead of deadlocking',
      () async {
    MessagesDatabase.setDatabaseForTest(_FailingWireReadDatabase());

    final rows = await MessagesDb.getMessageById('m1')
        .timeout(const Duration(seconds: 2));

    expect(rows, hasLength(1));
    // The fallback branch ran to completion: the failed wire read resolved
    // to null rather than hanging the caller forever.
    expect(rows.first['message'], isNull);
  });
}
