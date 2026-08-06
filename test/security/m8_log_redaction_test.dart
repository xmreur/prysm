import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/database/blocked_users_db.dart';
import 'package:prysm/server/inbound_message_router.dart';
import 'package:prysm/services/block_service.dart';
import 'package:prysm/services/settings_service.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/logging.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
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

  test('console output is scrubbed alongside the file (CR9)', () async {
    await Logging.init();
    final logPath = Logging.currentLogFilePath;
    expect(
      logPath,
      isNotNull,
      reason: 'Logging.init() must expose the log file path',
    );

    // debugPrint is a replaceable top-level hook (flutter_test itself swaps
    // it), so capturing it here catches exactly what the debug console
    // sink of Logging._write emits.
    final consoleLines = <String>[];
    final originalDebugPrint = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      consoleLines.add(message ?? '');
    };
    try {
      // Same payload shape as the real leak path: an exception whose
      // toString() embeds the peer onion, passed via the error: parameter.
      Logging.error(
        'ws transport error',
        'Test',
        error: Exception('WebSocket not connected to $fullOnion'),
      );
    } finally {
      debugPrint = originalDebugPrint;
    }

    final console = consoleLines.join('\n');
    expect(
      console.contains(fullOnion),
      isFalse,
      reason: 'the full onion must never reach the debug console',
    );
    expect(
      console,
      contains('k3yeek…'),
      reason: 'the redacted form must still reach the debug console',
    );

    final logContent = File(logPath!).readAsStringSync();
    expect(
      logContent.contains(fullOnion),
      isFalse,
      reason: 'the full onion must never reach the log file either',
    );
    expect(logContent, contains('k3yeek…'));
  });

  test('a full onion passed as fileAlias never reaches a sink (NR3)',
      () async {
    await Logging.init();
    final logPath = Logging.currentLogFilePath;
    expect(
      logPath,
      isNotNull,
      reason: 'Logging.init() must expose the log file path',
    );

    final consoleLines = <String>[];
    final originalDebugPrint = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      consoleLines.add(message ?? '');
    };
    try {
      // No call site passes an onion here today, so this guards the write
      // path: the alias is scrubbed like every other value before a sink.
      Logging.info('alias probe', fullOnion);
    } finally {
      debugPrint = originalDebugPrint;
    }

    final console = consoleLines.join('\n');
    expect(
      console.contains(fullOnion),
      isFalse,
      reason: 'a full onion in fileAlias must never reach the debug console',
    );
    expect(
      console,
      contains('k3yeek…'),
      reason: 'the redacted alias must still identify the source',
    );

    final logContent = File(logPath!).readAsStringSync();
    expect(
      logContent.contains(fullOnion),
      isFalse,
      reason: 'a full onion in fileAlias must never reach the log file either',
    );
    expect(logContent, contains('k3yeek…'));
  });

  test('shelf access log scrubs a requester onion (CR7)', () async {
    await Logging.init();
    final logPath = Logging.currentLogFilePath;
    expect(
      logPath,
      isNotNull,
      reason: 'Logging.init() must expose the log file path',
    );

    // Same pipeline shape as PrysmServer.start(): shelf's logRequests with
    // a logger that routes through Logging, so the central scrub applies to
    // the access line too.
    final handler = Pipeline()
        .addMiddleware(logRequests(logger: (message, isError) => isError
            ? Logging.error(message, 'PrysmServer')
            : Logging.info(message, 'PrysmServer')))
        .addHandler((Request request) => Response.ok('ok'));

    final consoleLines = <String>[];
    final originalDebugPrint = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      consoleLines.add(message ?? '');
    };
    // The test binding's mock HttpOverrides answers every HttpClient
    // request with an instant empty 400 without ever reaching this server;
    // the request must really hit the loopback socket for logRequests to
    // run. HttpOverrides.runZoned cannot replace this: its zero-argument
    // form inherits HttpOverrides.current, i.e. the binding's mock, so
    // clearing the global is the only way to get a real client. Setter-only
    // in this SDK; the remaining tests in this file make no HTTP calls, so
    // leaving the override cleared is safe.
    HttpOverrides.global = null;
    final server = await io.serve(handler, InternetAddress.loopbackIPv4, 0);
    try {
      final client = HttpClient();
      final request = await client.getUrl(Uri.parse(
          'http://127.0.0.1:${server.port}/profile?requester=$fullOnion'));
      final response = await request.close();
      expect(
        response.statusCode,
        200,
        reason: 'the request must really reach the loopback server; the '
            'test binding\'s mock answers 400 without touching it',
      );
      await response.drain<void>();
      client.close();
    } finally {
      await server.close(force: true);
      debugPrint = originalDebugPrint;
    }

    final console = consoleLines.join('\n');
    expect(
      console.contains(fullOnion),
      isFalse,
      reason: 'the shelf access line must never reach the console with a '
          'full onion',
    );
    expect(console, contains('k3yeek…'));

    final logContent = File(logPath!).readAsStringSync();
    expect(
      logContent.contains(fullOnion),
      isFalse,
      reason: 'the shelf access line must never reach the log file with a '
          'full onion',
    );
    expect(
      logContent,
      contains('k3yeek…'),
      reason: 'the scrubbed access line must still be logged',
    );
  });
}
