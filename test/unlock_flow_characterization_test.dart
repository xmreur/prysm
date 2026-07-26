// Characterization tests for the unlock flow (Fase 5A).
//
// Originally fixed the behavior of `_MyAppState.onVerifyUnlock`
// (main.dart) before it was extracted; now exercises `UnlockController`
// directly, proving the extraction preserved behavior — the assertions
// below never changed across that extraction.
//
// `_MyAppState` is private and its `initState` kicks off real network/Tor
// bootstrap work, so it cannot safely be exercised by pumping `MyApp`
// directly (see `offline_startup_test.dart` for the established pattern of
// mirroring private `_MyAppState`/`_HomeScreenState` logic in a standalone
// test instead of pumping the monolith). `UnlockController` sidesteps that
// entirely: it has no widget/State dependency at all.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/app/unlock_controller.dart';
import 'package:prysm/crypto/key_store.dart';
import 'package:prysm/models/panic_action.dart';
import 'package:prysm/models/unlock_type.dart';
import 'package:prysm/services/panic_pin_service.dart';
import 'package:prysm/services/settings_service.dart';
import 'package:prysm/services/unlock_lockout_service.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory docsDir;
  // Backs every FlutterSecureStorage() instance process-wide (Android
  // options etc. only change the channel *arguments*, not the channel),
  // including PanicPinService's and PanicWipeService's raw
  // (non-CryptoKeyStore) storage. Same technique already used below for
  // path_provider — mock the platform channel directly instead of adding a
  // new package dependency.
  final secureStorageData = <String, String>{};

  Future<Object?> handleSecureStorageCall(MethodCall call) async {
    final args = (call.arguments as Map).cast<String, dynamic>();
    switch (call.method) {
      case 'read':
        return secureStorageData[args['key'] as String];
      case 'write':
        secureStorageData[args['key'] as String] = args['value'] as String;
        return null;
      case 'delete':
        secureStorageData.remove(args['key'] as String);
        return null;
      case 'deleteAll':
        secureStorageData.clear();
        return null;
      case 'containsKey':
        return secureStorageData.containsKey(args['key'] as String);
      case 'readAll':
        return secureStorageData;
      default:
        return null;
    }
  }

  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;

    // PanicWipeService.wipeAll() shells out to path_provider for the
    // on-disk db files it deletes.
    docsDir = Directory.systemTemp.createTempSync('unlock_flow_char_test');
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
      handleSecureStorageCall,
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

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    CryptoKeyStore.setUseInMemoryStorageOnly(true);
    CryptoKeyStore.resetInMemoryStorageForTest();
    UnlockLockoutService.setUseInMemoryStorageOnly(true);
    UnlockLockoutService.resetForTest();
    secureStorageData.clear();

    final settings = SettingsService();
    await settings.init();
  });

  tearDown(() {
    CryptoKeyStore.setUseInMemoryStorageOnly(false);
    UnlockLockoutService.setUseInMemoryStorageOnly(false);
  });

  group('correct passphrase', () {
    test('unlocks, clears lockout, is not a decoy session', () async {
      const passphrase = 'correct-horse-battery-staple';
      final settings = SettingsService();
      await settings.setUnlockType(UnlockType.passphrase);

      // Establish the passphrase like a real prior session would.
      await KeyManager().unlockWithPassphrase(
        passphrase,
        type: UnlockType.passphrase,
      );

      final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
      await db.execute('CREATE TABLE users (id TEXT PRIMARY KEY)');
      DBHelper.setDatabaseForTest(db);
      addTearDown(() => DBHelper.setDatabaseForTest(null));

      final keyManager = KeyManager();
      final controller = UnlockController(
        keyManager: keyManager,
        settings: settings,
      );
      final result = await controller.verifyUnlock(passphrase);

      expect(result.unlocked, isTrue);
      expect(result.decoySession, isFalse);
      expect(keyManager.isUnlocked, isTrue);
      expect(await UnlockLockoutService.instance.attemptsRemaining(), 5);
    });
  });

  group('wrong passphrase', () {
    test('fails and increments the lockout failure count', () async {
      const passphrase = 'correct-horse-battery-staple';
      final settings = SettingsService();
      await settings.setUnlockType(UnlockType.passphrase);
      await KeyManager().unlockWithPassphrase(
        passphrase,
        type: UnlockType.passphrase,
      );

      expect(await UnlockLockoutService.instance.attemptsRemaining(), 5);

      final controller = UnlockController(
        keyManager: KeyManager(),
        settings: settings,
      );
      final result = await controller.verifyUnlock(
        'totally-the-wrong-passphrase',
      );

      expect(result.unlocked, isFalse);
      expect(await UnlockLockoutService.instance.attemptsRemaining(), 4);
    });
  });

  group('active lockout', () {
    test('rejects even a correct passphrase without attempting it', () async {
      const passphrase = 'correct-horse-battery-staple';
      final settings = SettingsService();
      await settings.setUnlockType(UnlockType.passphrase);
      final setupKeyManager = KeyManager();
      await setupKeyManager.unlockWithPassphrase(
        passphrase,
        type: UnlockType.passphrase,
      );

      for (var i = 0; i < UnlockLockoutService.maxAttempts; i++) {
        await UnlockLockoutService.instance.recordPrimaryFailure();
      }
      expect(await UnlockLockoutService.instance.isLockedOut(), isTrue);

      final keyManager = KeyManager();
      final controller = UnlockController(
        keyManager: keyManager,
        settings: settings,
      );
      final result = await controller.verifyUnlock(passphrase);

      expect(result.unlocked, isFalse);
      expect(keyManager.isUnlocked, isFalse);
    });
  });

  group('panic PIN', () {
    test('wipe action triggers a full wipe and a decoy session', () async {
      const panicPin = '654321';
      final settings = SettingsService();
      await settings.setUnlockType(UnlockType.passphrase);
      await settings.setPanicAction(PanicAction.wipe);
      await PanicPinService.instance.setPin(panicPin);
      expect(await PanicPinService.instance.isConfigured(), isTrue);

      final keyManager = KeyManager();
      final controller = UnlockController(
        keyManager: keyManager,
        settings: settings,
      );
      final result = await controller.verifyUnlock(panicPin);

      expect(result.unlocked, isTrue);
      expect(result.decoySession, isTrue);
      expect(keyManager.isUnlocked, isTrue);
      // wipeAll() cleared the shared secure storage fake, including the
      // panic PIN itself.
      expect(await PanicPinService.instance.isConfigured(), isFalse);
    });

    test('decoy action locks without wiping stored data', () async {
      const panicPin = '135790';
      final settings = SettingsService();
      await settings.setUnlockType(UnlockType.passphrase);
      await settings.setPanicAction(PanicAction.decoy);
      await PanicPinService.instance.setPin(panicPin);

      final keyManager = KeyManager();
      final controller = UnlockController(
        keyManager: keyManager,
        settings: settings,
      );
      final result = await controller.verifyUnlock(panicPin);

      expect(result.unlocked, isTrue);
      expect(result.decoySession, isTrue);
      expect(keyManager.isUnlocked, isTrue);
      // No wipe: the panic PIN itself is still configured afterwards.
      expect(await PanicPinService.instance.isConfigured(), isTrue);
    });
  });

  group('injected seams', () {
    test('ctor injection overrides panic-PIN check and wipe', () async {
      final settings = SettingsService();
      await settings.setUnlockType(UnlockType.passphrase);
      await settings.setPanicAction(PanicAction.wipe);

      var wipeCalled = false;
      final keyManager = KeyManager();
      final controller = UnlockController(
        keyManager: keyManager,
        settings: settings,
        isPanicPinConfigured: () async => true,
        verifyPanicPin: (pin) async => pin == '000000',
        wipeAll: () async {
          wipeCalled = true;
        },
      );

      final result = await controller.verifyUnlock('000000');

      expect(result.unlocked, isTrue);
      expect(result.decoySession, isTrue);
      expect(wipeCalled, isTrue);
      // The real PanicPinService was never configured/consulted.
      expect(await PanicPinService.instance.isConfigured(), isFalse);
    });
  });
}
