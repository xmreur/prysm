import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:prysm/services/settings_service.dart';
import 'package:prysm/services/unlock_lockout_service.dart';
import 'package:prysm/util/biometrics.dart';

/// Stores the unlock secret for biometric convenience unlock on Android.
class BiometricUnlockService {
  BiometricUnlockService._();
  static final BiometricUnlockService instance = BiometricUnlockService._();

  static const _secretKey = 'BIOMETRIC_UNLOCK_SECRET';

  static const _secureStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  static final Map<String, String> _testMemory = {};
  static bool _useTestMemoryOnly = false;

  @visibleForTesting
  static bool forceSupportedForTest = false;

  @visibleForTesting
  static bool? availabilityOverrideForTest;

  static bool get isSupported => forceSupportedForTest || Platform.isAndroid;

  @visibleForTesting
  static void setUseInMemoryStorageOnly(bool value) {
    if (value) _testMemory.clear();
    _useTestMemoryOnly = value;
  }

  @visibleForTesting
  static void resetForTest() {
    _testMemory.clear();
  }

  static Future<String?> _read(String key) async {
    if (_useTestMemoryOnly) return _testMemory[key];
    try {
      return await _secureStorage.read(key: key);
    } catch (_) {
      return _testMemory[key];
    }
  }

  static Future<void> _write(String key, String value) async {
    if (_useTestMemoryOnly) {
      _testMemory[key] = value;
      return;
    }
    try {
      await _secureStorage.write(key: key, value: value);
    } catch (_) {
      _testMemory[key] = value;
    }
  }

  static Future<void> _delete(String key) async {
    if (_useTestMemoryOnly) {
      _testMemory.remove(key);
      return;
    }
    try {
      await _secureStorage.delete(key: key);
    } catch (_) {
      _testMemory.remove(key);
    }
  }

  Future<bool> isAvailable() async {
    if (availabilityOverrideForTest != null) {
      return availabilityOverrideForTest!;
    }
    return Biometrics.isAvailable;
  }

  Future<bool> hasStoredSecret() async {
    final secret = await _read(_secretKey);
    return secret != null && secret.isNotEmpty;
  }

  Future<void> storeSecret(String secret) async {
    await _write(_secretKey, secret);
  }

  Future<String?> readSecret() => _read(_secretKey);

  Future<void> clear() => _delete(_secretKey);

  Future<bool> canAttemptUnlock() async {
    if (!isSupported) return false;
    if (!SettingsService().biometricsEnabled) return false;
    if (!await hasStoredSecret()) return false;
    if (!await isAvailable()) return false;
    if (await UnlockLockoutService.instance.isLockedOut()) return false;
    return true;
  }

  /// Prompts biometrics and returns the stored unlock secret on success.
  Future<String?> unlockWithBiometrics() async {
    if (!await canAttemptUnlock()) return null;
    final ok = await Biometrics.authenticateForUnlock();
    if (!ok) return null;
    return readSecret();
  }
}
