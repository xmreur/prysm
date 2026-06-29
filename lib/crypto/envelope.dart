import 'dart:convert';
import 'dart:typed_data';

import 'package:prysm/crypto/constants.dart';

/// Versioned crypto envelope helpers.
class CryptoEnvelope {
  CryptoEnvelope._();

  static Map<String, dynamic> dhAead1({
    required Uint8List ephemeralPublic,
    required Uint8List ciphertext,
    required Uint8List nonce,
    String alg = 'aes-gcm',
  }) {
    return {
      'crypto': CryptoConstants.cryptoVersion,
      'scheme': CryptoConstants.schemeDhAead1,
      'alg': alg,
      'ephemeralPub': base64Encode(ephemeralPublic),
      'nonce': base64Encode(nonce),
      'ciphertext': base64Encode(ciphertext),
    };
  }

  static Map<String, dynamic> groupAead1({
    required Uint8List iv,
    required Uint8List ciphertext,
  }) {
    return {
      'crypto': CryptoConstants.cryptoVersion,
      'scheme': CryptoConstants.schemeGroupAead1,
      'iv': base64Encode(iv),
      'ct': base64Encode(ciphertext),
    };
  }

  static Map<String, dynamic> controlWrap1({
    required Map<String, dynamic> wrappedKey,
    required Uint8List iv,
    required Uint8List ciphertext,
  }) {
    return {
      'crypto': CryptoConstants.cryptoVersion,
      'scheme': CryptoConstants.schemeControlWrap1,
      'wrappedKey': wrappedKey,
      'iv': base64Encode(iv),
      'ct': base64Encode(ciphertext),
    };
  }

  static Map<String, dynamic> fileAead1({
    required Map<String, dynamic> wrappedKey,
    required Uint8List nonce,
    required Uint8List ciphertext,
  }) {
    return {
      'crypto': CryptoConstants.cryptoVersion,
      'scheme': CryptoConstants.schemeFileAead1,
      'wrappedKey': wrappedKey,
      'nonce': base64Encode(nonce),
      'ciphertext': base64Encode(ciphertext),
    };
  }

  static Map<String, dynamic>? tryParse(String wire) {
    final trimmed = wire.trimLeft();
    if (!trimmed.startsWith('{')) return null;
    try {
      final parsed = jsonDecode(wire);
      if (parsed is! Map<String, dynamic>) return null;
      if (parsed['crypto'] != CryptoConstants.cryptoVersion) return null;
      return parsed;
    } catch (_) {
      return null;
    }
  }

  static String encode(Map<String, dynamic> envelope) => jsonEncode(envelope);

  static bool isV2(String wire) => tryParse(wire) != null;

  static String schemeOf(Map<String, dynamic> envelope) {
    final scheme = envelope['scheme'];
    if (scheme is! String) {
      throw FormatException('Missing scheme in crypto envelope');
    }
    return scheme;
  }
}
