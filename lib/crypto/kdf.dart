import 'dart:math';
import 'dart:typed_data';

import 'package:argon2/argon2.dart';
import 'package:cryptography/cryptography.dart';
import 'package:prysm/crypto/constants.dart';

/// Key derivation (Argon2id + HKDF).
class CryptoKdf {
  CryptoKdf._();

  static Uint8List randomBytes(int length) {
    final rnd = Random.secure();
    return Uint8List.fromList(List.generate(length, (_) => rnd.nextInt(256)));
  }

  /// Derive a 32-byte key from [passphrase] using Argon2id.
  static Uint8List deriveKeyFromPassphrase(String passphrase, Uint8List salt) {
    final params = Argon2Parameters(
      Argon2Parameters.ARGON2_id,
      salt,
      iterations: CryptoConstants.argon2Iterations,
      memory: CryptoConstants.argon2MemoryKiB,
      lanes: CryptoConstants.argon2Lanes,
    );
    final generator = Argon2BytesGenerator()..init(params);
    final out = Uint8List(CryptoConstants.aeadKeyLength);
    generator.generateBytesFromString(passphrase, out);
    return out;
  }

  /// Hash passphrase for verification (panic PIN etc.).
  static Uint8List hashPassphrase(String passphrase, Uint8List salt) {
    return deriveKeyFromPassphrase(passphrase, salt);
  }

  static Future<SecretKey> hkdf({
    required List<int> sharedSecret,
    required List<int> info,
    List<int>? salt,
    int outputLength = CryptoConstants.aeadKeyLength,
  }) async {
    final hkdf = Hkdf(
      hmac: Hmac.sha256(),
      outputLength: outputLength,
    );
    return hkdf.deriveKey(
      secretKey: SecretKey(sharedSecret),
      info: info,
      nonce: salt ?? const [],
    );
  }

  static bool constantTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }
}
