import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/database/blocked_users_db.dart';
import 'package:prysm/server/inbound_message_router.dart';
import 'package:prysm/services/block_service.dart';
import 'package:prysm/services/settings_service.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/logging.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// M8: peer onions must never reach the log file in full, even at error/info
/// level (release builds write everything >= info to disk).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // A valid-length Tor v3 onion (56 base32 chars + '.onion').
  final onionBody = 'k3yeek${List.filled(50, 'x').join()}';
  final fullOnion = '$onionBody.onion';

  late Directory tempDir;
  late InboundMessageRouter router;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('m8_log_redaction_test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async {
        if (call.method == 'getTemporaryDirectory') {
          return tempDir.path;
        }
        return null;
      },
    );

    final db = await databaseFactory.openDatabase(
      '${inMemoryDatabasePath}_${DateTime.now().microsecondsSinceEpoch}',
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, _) async {
          await BlockedUsersDb.createTable(db);
        },
      ),
    );
    DBHelper.setDatabaseForTest(db);
    await BlockService.instance.init();
    // The sender is blocked so processMessage short-circuits right after the
    // log line: this keeps the test focused on the logging path only.
    await BlockService.instance.block(fullOnion);

    router = InboundMessageRouter(
      keyManager: KeyManager(),
      settings: SettingsService(),
      localOnionAddress: () => 'local.onion',
    );
  });

  tearDown(() async {
    DBHelper.setDatabaseForTest(null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  test('redactOnion truncates a full v3 onion and never contains it', () {
    final redacted = Logging.redactOnion(fullOnion);

    expect(redacted, 'k3yeek…');
    expect(redacted.contains(fullOnion), isFalse);
  });

  test('processMessage never writes the full peer onion to the log file',
      () async {
    await Logging.init();
    final logPath = Logging.currentLogFilePath;
    expect(
      logPath,
      isNotNull,
      reason: 'Logging.init() must expose the log file path',
    );

    final result = await router.processMessage({
      'id': 'msg-redact-1',
      'senderId': fullOnion,
      'receiverId': 'local.onion',
      'message': 'cipher',
      'type': 'text',
      'timestamp': 1,
    });

    expect(result.statusCode, 200);
    expect(result.jsonBody?['status'], 'received');

    final logContent = File(logPath!).readAsStringSync();
    expect(
      logContent.contains(fullOnion),
      isFalse,
      reason: 'the peer onion must never appear in the log file',
    );
    expect(
      logContent,
      contains('k3yeek…'),
      reason: 'the redacted prefix must still be logged for debugging',
    );
  });

  test('exceptions embedding a full onion are scrubbed before writing',
      () async {
    await Logging.init();
    final logPath = Logging.currentLogFilePath;
    expect(
      logPath,
      isNotNull,
      reason: 'Logging.init() must expose the log file path',
    );

    // Real leak path from the Task 6 review: StateError('WebSocket not
    // connected to <onion>') interpolated via $e / error: at redacted call
    // sites. Per-call-site redaction cannot intercept these, so the write
    // path itself must scrub the final line.
    final err = StateError('WebSocket not connected to $fullOnion');
    Logging.error('ws failed: $err', 'Test');
    Logging.error('ws send failed', 'Test', error: err);

    final logContent = File(logPath!).readAsStringSync();
    expect(
      logContent.contains(fullOnion),
      isFalse,
      reason: 'an onion inside an exception toString() must never reach the '
          'log file, even when the call site only interpolated the error',
    );
    expect(
      logContent,
      contains('WebSocket not connected to k3yeek…'),
      reason: 'the scrubbed form must still be logged for debugging',
    );
  });
}
