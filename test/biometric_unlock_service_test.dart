import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/services/biometric_unlock_service.dart';
import 'package:prysm/services/settings_service.dart';
import 'package:prysm/services/unlock_lockout_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await SettingsService().init();
    await SettingsService().setBiometricsEnabled(false);

    BiometricUnlockService.setUseInMemoryStorageOnly(true);
    BiometricUnlockService.resetForTest();
    BiometricUnlockService.forceSupportedForTest = true;
    BiometricUnlockService.availabilityOverrideForTest = true;

    UnlockLockoutService.setUseInMemoryStorageOnly(true);
    UnlockLockoutService.resetForTest();
  });

  tearDown(() {
    BiometricUnlockService.setUseInMemoryStorageOnly(false);
    BiometricUnlockService.forceSupportedForTest = false;
    BiometricUnlockService.availabilityOverrideForTest = null;
    UnlockLockoutService.setUseInMemoryStorageOnly(false);
  });

  test('store read clear round-trip', () async {
    final service = BiometricUnlockService.instance;
    expect(await service.hasStoredSecret(), isFalse);

    await service.storeSecret('123456');
    expect(await service.hasStoredSecret(), isTrue);
    expect(await service.readSecret(), '123456');

    await service.clear();
    expect(await service.hasStoredSecret(), isFalse);
    expect(await service.readSecret(), isNull);
  });

  test('canAttemptUnlock requires enabled setting and stored secret', () async {
    final service = BiometricUnlockService.instance;

    expect(await service.canAttemptUnlock(), isFalse);

    await service.storeSecret('123456');
    expect(await service.canAttemptUnlock(), isFalse);

    await SettingsService().setBiometricsEnabled(true);
    expect(await service.canAttemptUnlock(), isTrue);
  });

  test('canAttemptUnlock blocked during lockout', () async {
    final service = BiometricUnlockService.instance;
    await service.storeSecret('123456');
    await SettingsService().setBiometricsEnabled(true);

    for (var i = 0; i < 5; i++) {
      await UnlockLockoutService.instance.recordPrimaryFailure();
    }

    expect(await service.canAttemptUnlock(), isFalse);
  });
}
