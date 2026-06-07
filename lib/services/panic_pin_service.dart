import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pointycastle/export.dart';

class PanicPinService {
  PanicPinService._();
  static final PanicPinService instance = PanicPinService._();

  static const _hashKey = 'PANIC_PIN_HASH';
  static const _saltKey = 'PANIC_PIN_SALT';
  static const _secureStorage = FlutterSecureStorage();

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
    return _constantTimeEquals(
      base64Decode(storedHash),
      base64Decode(computed),
    );
  }

  Future<void> setPin(String pin) async {
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

  static bool _constantTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  static String _hashPinIsolate(Map<String, String> params) {
    final pin = params['pin']!;
    final salt = base64Decode(params['saltB64']!);
    final pbkdf2 = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64));
    pbkdf2.init(Pbkdf2Parameters(salt, 100_000, 32));
    final hash = pbkdf2.process(utf8.encode(pin));
    return base64Encode(hash);
  }
}
