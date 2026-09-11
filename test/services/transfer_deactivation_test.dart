// deactivateForTransfer: stop + verify dead, HS delete + verify absent,
// restart suppression (fail-closed), and wipeForTransfer propagation.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/services/panic_wipe_service.dart';
import 'package:prysm/util/hs_transfer_keys.dart';
import 'package:prysm/util/tor_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeTorManager {
  _FakeTorManager(this.deactivateResult);

  final bool deactivateResult;
  int deactivateCalls = 0;

  Future<bool> deactivateForTransfer() async {
    deactivateCalls++;
    return deactivateResult;
  }
}

String _b64(List<int> bytes) => base64Encode(bytes);

Map<String, String> _goodKeys() => {
  'hostname': _b64(utf8.encode("${'z' * 56}.onion")),
  'hs_ed25519_secret_key': _b64(List.filled(96, 7)),
  'hs_ed25519_public_key': _b64(List.filled(32, 9)),
};

void main() {
  test('deactivateForTransfer removes HS keys, verifies absence, '
      'then refuses start/restart', () async {
    final dataDir = Directory.systemTemp.createTempSync('deactivate_test').path;
    final manager = TorManager(
      torPath: '/nonexistent/tor',
      dataDir: dataDir,
      controlPort: 19876,
      controlPassword: 'test-password',
    );
    final hsDir = '$dataDir/hidden_service';
    expect(await HsTransferKeys.installToDirectory(hsDir, _goodKeys()), isTrue);

    expect(await manager.deactivateForTransfer(), isTrue);
    expect(manager.isDeactivatedForTransfer, isTrue);
    expect(Directory(hsDir).existsSync(), isFalse);

    expect(() => manager.startTor(), throwsStateError);
    expect(() => manager.restartTor(), throwsStateError);

    Directory(dataDir).deleteSync(recursive: true);
  });

  test('concurrent install and delete never leave a mixed key set', () async {
    final dir =
        '${Directory.systemTemp.path}/hs_race_${DateTime.now().microsecondsSinceEpoch}';
    Future<void> hammer(int seed) async {
      if (seed.isEven) {
        await HsTransferKeys.installToDirectory(dir, _goodKeys());
      } else {
        await HsTransferKeys.deleteDirectory(dir);
      }
    }

    for (var round = 0; round < 20; round++) {
      await Future.wait([for (var i = 0; i < 8; i++) hammer(i)]);
      final present = [
        'hostname',
        'hs_ed25519_secret_key',
        'hs_ed25519_public_key',
      ].map((n) => File('$dir/$n').existsSync()).toList();
      // Serialized mutations land in whole states only.
      expect(
        present.every((p) => p) || present.every((p) => !p),
        isTrue,
        reason: 'round $round left a mixed set: $present',
      );
    }
    await HsTransferKeys.deleteDirectory(dir);
  });

  group('wipeForTransfer', () {
    late Directory docsDir;

    setUpAll(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues({});
      docsDir = Directory.systemTemp.createTempSync('wipe_transfer_test');
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

    test('returns the deactivation result instead of swallowing it', () async {
      final ok = _FakeTorManager(true);
      expect(await PanicWipeService.wipeForTransfer(torManager: ok), isTrue);
      expect(ok.deactivateCalls, 1);

      final failed = _FakeTorManager(false);
      expect(
        await PanicWipeService.wipeForTransfer(torManager: failed),
        isFalse,
      );
      expect(failed.deactivateCalls, 1);
    });
  });
}
