import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Tracks failed primary unlock attempts and enforces a timed lockout.
class UnlockLockoutService {
  UnlockLockoutService._();
  static final UnlockLockoutService instance = UnlockLockoutService._();

  static const int maxAttempts = 5;
  static const Duration lockoutDuration = Duration(hours: 2);

  static const _failCountKey = 'UNLOCK_FAIL_COUNT';
  static const _lockedUntilKey = 'UNLOCK_LOCKED_UNTIL_MS';

  static const _secureStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  static final Map<String, String> _testMemory = {};

  @visibleForTesting
  static void setUseInMemoryStorageOnly(bool value) {
    if (value) {
      _testMemory.clear();
    }
    _useTestMemoryOnly = value;
  }

  static bool _useTestMemoryOnly = false;

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

  Future<void> _clearState() async {
    await _delete(_failCountKey);
    await _delete(_lockedUntilKey);
  }

  Future<int> _failCount() async {
    final raw = await _read(_failCountKey);
    return int.tryParse(raw ?? '') ?? 0;
  }

  Future<int?> _lockedUntilMs() async {
    final raw = await _read(_lockedUntilKey);
    return int.tryParse(raw ?? '');
  }

  Future<bool> isLockedOut() async {
    final until = await _lockedUntilMs();
    if (until == null) return false;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now >= until) {
      await _clearState();
      return false;
    }
    return true;
  }

  Future<Duration?> remainingLockout() async {
    final until = await _lockedUntilMs();
    if (until == null) return null;
    final remaining = Duration(
      milliseconds: until - DateTime.now().millisecondsSinceEpoch,
    );
    if (remaining.isNegative) {
      await _clearState();
      return null;
    }
    return remaining;
  }

  Future<int> attemptsRemaining() async {
    if (await isLockedOut()) return 0;
    final count = await _failCount();
    return maxAttempts - count;
  }

  Future<void> recordPrimaryFailure() async {
    if (await isLockedOut()) return;
    final count = await _failCount() + 1;
    if (count >= maxAttempts) {
      final until =
          DateTime.now().add(lockoutDuration).millisecondsSinceEpoch;
      await _write(_lockedUntilKey, '$until');
      await _delete(_failCountKey);
      return;
    }
    await _write(_failCountKey, '$count');
  }

  Future<void> recordSuccess() async {
    await _clearState();
  }

  @visibleForTesting
  Future<void> clear() => _clearState();
}
