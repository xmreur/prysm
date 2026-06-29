import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:prysm/crypto/kdf.dart';

class PanicPinService {
  PanicPinService._();
  static final PanicPinService instance = PanicPinService._();

  static const _hashKey = 'PANIC_PIN_HASH';
  static const _saltKey = 'PANIC_PIN_SALT';
  static const _secureStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  Future<bool> isConfigured() async {
    final hash = await _secureStorage.read(key: _hashKey);
    final salt = await _secureStorage.read(key: _saltKey);
    return hash != null && salt != null;
  }

  Future<bool> verify(String pin) async {
    if (pin.length != 6) return false;
    final storedHash = await _secureStorage.read(key: _hashKey);
    final saltB64 = await _secureStorage.read(key: _saltKey);
    if (storedHash == null || saltB64 == null) return false;

    final computed = await compute(_hashPinIsolate, {
      'pin': pin,
      'saltB64': saltB64,
    });
    return CryptoKdf.constantTimeEquals(
      base64Decode(storedHash),
      base64Decode(computed),
    );
  }

  Future<void> setPin(String pin) async {
    if (pin.length != 6) {
      throw ArgumentError('Panic PIN must be 6 digits');
    }
    final salt = _randomBytes(16);
    final hash = await compute(_hashPinIsolate, {
      'pin': pin,
      'saltB64': base64Encode(salt),
    });
    await _secureStorage.write(key: _hashKey, value: hash);
    await _secureStorage.write(key: _saltKey, value: base64Encode(salt));
  }

  Future<void> clear() async {
    await _secureStorage.delete(key: _hashKey);
    await _secureStorage.delete(key: _saltKey);
  }

  static Uint8List _randomBytes(int length) {
    final rnd = Random.secure();
    return Uint8List.fromList(List.generate(length, (_) => rnd.nextInt(256)));
  }

  static String _hashPinIsolate(Map<String, String> params) {
    final pin = params['pin']!;
    final salt = base64Decode(params['saltB64']!);
    final hash = CryptoKdf.hashPassphrase(pin, salt);
    return base64Encode(hash);
  }
}
