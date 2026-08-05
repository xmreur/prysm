// Panic wipe must destroy the SQLCipher WAL/SHM sidecars of each database:
// since H6, the databases are encrypted at rest, but `-wal`/`-shm` can carry
// plaintext pages, so leaving them behind after a wipe defeats the wipe.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/services/panic_wipe_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Directory docsDir;

  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});

    // PanicWipeService.wipeAll() shells out to path_provider for the
    // on-disk db files it deletes; point it at a throwaway temp directory
    // the same way the other tests do (mock the platform channel).
    docsDir = Directory.systemTemp.createTempSync('panic_wipe_sidecars_test');
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
    // wipeAll() also clears FlutterSecureStorage directly (and the panic PIN,
    // which lives there too); mock the channel so those calls are no-ops.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async => null,
    );
  });

  tearDownAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      null,
    );
    docsDir.deleteSync(recursive: true);
  });

  test('wipeAll deletes each database together with its -wal and -shm sidecars', () async {
    final prysmDir = Directory('${docsDir.path}/prysm')
      ..createSync(recursive: true);

    const dbNames = ['chat_app.db', 'messages.db', 'pending_messages.db'];
    final files = <File>[];
    for (final name in dbNames) {
      // A crash mid-migration leaves a $name.migrating temp behind; the
      // wipe must destroy it too, or the next launch's recovery path would
      // resurrect the database after a wipe.
      for (final suffix in ['', '-wal', '-shm', '.migrating']) {
        final file = File('${prysmDir.path}/$name$suffix');
        file.writeAsBytesSync([1, 2, 3]);
        files.add(file);
      }
    }
    expect(files.every((f) => f.existsSync()), isTrue,
        reason: 'precondition: all twelve files exist');

    await PanicWipeService.wipeAll();

    for (final file in files) {
      expect(file.existsSync(), isFalse,
          reason: '${file.path} must be deleted by the panic wipe');
    }
  });
}
