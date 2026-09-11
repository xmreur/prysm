// deactivateForTransfer: stop + verify dead, HS delete + verify absent,
// restart suppression (fail-closed), and wipeForTransfer propagation.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/services/panic_wipe_service.dart';
import 'package:prysm/util/hs_transfer_keys.dart';
import 'package:prysm/util/tor_service.dart';

import '../support/hs_fixtures.dart';
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

Map<String, String> _goodKeys() => validHsTriplet();

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

  test(
    'interrupted install is repaired before Tor can read the keys',
    () async {
      final dataDir = Directory.systemTemp
          .createTempSync('hs_repair_test')
          .path;
      final hsDir = '$dataDir/hidden_service';
      expect(
        await HsTransferKeys.installToDirectory(hsDir, validHsTriplet()),
        isTrue,
      );
      // A clean install leaves no marker.
      expect(
        File('$hsDir/${HsTransferKeys.pendingMarkerFile}').existsSync(),
        isFalse,
      );
      expect(await HsTransferKeys.repairInterruptedInstall(hsDir), isFalse);
      expect(File('$hsDir/hostname').existsSync(), isTrue);

      // Simulate a process death between promotes: marker plus a half-new set.
      File(
        '$hsDir/${HsTransferKeys.pendingMarkerFile}',
      ).writeAsStringSync('installing');
      expect(await HsTransferKeys.repairInterruptedInstall(hsDir), isTrue);
      for (final name in [
        'hostname',
        'hs_ed25519_secret_key',
        'hs_ed25519_public_key',
        HsTransferKeys.pendingMarkerFile,
      ]) {
        expect(File('$hsDir/$name').existsSync(), isFalse, reason: name);
      }

      Directory(dataDir).deleteSync(recursive: true);
    },
  );

  test('malformed-but-decodable key material is rejected', () async {
    final dir = Directory.systemTemp.createTempSync('hs_validate_test').path;
    // Right lengths, wrong Tor headers.
    expect(
      await HsTransferKeys.installToDirectory(dir, {
        HsTransferKeys.hostnameFile: base64Encode(
          utf8.encode('${'z' * 56}.onion'),
        ),
        HsTransferKeys.secretKeyFile: base64Encode(List.filled(96, 7)),
        HsTransferKeys.publicKeyFile: base64Encode(List.filled(64, 9)),
      }),
      isFalse,
    );
    // Valid files, hostname of another identity.
    expect(
      await HsTransferKeys.installToDirectory(dir, {
        ...validHsTriplet(seed: 4),
        HsTransferKeys.hostnameFile: validHsTriplet(
          seed: 5,
        )[HsTransferKeys.hostnameFile]!,
      }),
      isFalse,
    );
    expect(File('$dir/hostname').existsSync(), isFalse);
    expect(
      HsTransferKeys.isValidEncodedTriplet(validHsTriplet(seed: 6)),
      isTrue,
    );
    Directory(dir).deleteSync(recursive: true);
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
