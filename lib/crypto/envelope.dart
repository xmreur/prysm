import 'dart:convert';
import 'dart:typed_data';

import 'package:prysm/crypto/constants.dart';

/// Versioned crypto envelope helpers.
class CryptoEnvelope {
  CryptoEnvelope._();

  /// Canonical header AAD: "v2|scheme|alg"
  static List<int> headerAad({
    required String scheme,
    String alg = 'aes-gcm',
    String crypto = CryptoConstants.cryptoVersion,
  }) =>
      utf8.encode('$crypto|$scheme|$alg');

  /// Ratchet AAD: header (wire scheme) + counter + optional bootstrap handshake.
  static List<int> ratchetAad({
    required String scheme,
    required int counter,
    String alg = 'aes-gcm',
    String crypto = CryptoConstants.cryptoVersion,
    Map<String, dynamic>? handshake,
  }) {
    final header = '$crypto|$scheme|$alg|$counter';
    if (handshake == null || handshake.isEmpty) {
      return utf8.encode(header);
    }
    final ephemeralPub = handshake['ephemeralPub'] as String? ?? '';
    final oneTimePreKey = handshake['oneTimePreKey'] as String? ?? '';
    return utf8.encode('$header|$ephemeralPub|$oneTimePreKey');
  }

  /// Returns header AAD for -2 DH-AEAD schemes; empty for legacy -1.
  static List<int> dhAeadAssociatedData(Map<String, dynamic> envelope) {
    final scheme = schemeOf(envelope);
    if (scheme == CryptoConstants.schemeDhAead2 ||
        scheme == CryptoConstants.schemeDmSigned2) {
      return headerAad(
        scheme: scheme,
        alg: envelope['alg'] as String? ?? 'aes-gcm',
        crypto: envelope['crypto'] as String? ?? CryptoConstants.cryptoVersion,
      );
    }
    return const [];
  }

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

  static Map<String, dynamic> dhAead2({
    required Uint8List ephemeralPublic,
    required Uint8List ciphertext,
    required Uint8List nonce,
    String alg = 'aes-gcm',
  }) {
    return {
      'crypto': CryptoConstants.cryptoVersion,
      'scheme': CryptoConstants.schemeDhAead2,
      'alg': alg,
      'ephemeralPub': base64Encode(ephemeralPublic),
      'nonce': base64Encode(nonce),
      'ciphertext': base64Encode(ciphertext),
    };
  }

  static Map<String, dynamic> dmSigned1({
    required Uint8List ephemeralPublic,
    required Uint8List ciphertext,
    required Uint8List nonce,
    required List<int> signature,
    String alg = 'aes-gcm',
  }) {
    return {
      'crypto': CryptoConstants.cryptoVersion,
      'scheme': CryptoConstants.schemeDmSigned1,
      'alg': alg,
      'ephemeralPub': base64Encode(ephemeralPublic),
      'nonce': base64Encode(nonce),
      'ciphertext': base64Encode(ciphertext),
      'sig': base64Encode(signature),
    };
  }

  static Map<String, dynamic> dmSigned2({
    required Uint8List ephemeralPublic,
    required Uint8List ciphertext,
    required Uint8List nonce,
    required List<int> signature,
    String alg = 'aes-gcm',
  }) {
    return {
      'crypto': CryptoConstants.cryptoVersion,
      'scheme': CryptoConstants.schemeDmSigned2,
      'alg': alg,
      'ephemeralPub': base64Encode(ephemeralPublic),
      'nonce': base64Encode(nonce),
      'ciphertext': base64Encode(ciphertext),
      'sig': base64Encode(signature),
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

  static Map<String, dynamic> fileSigned1({
    required Map<String, dynamic> wrappedKey,
    required Uint8List nonce,
    required Uint8List ciphertext,
  }) {
    return {
      'crypto': CryptoConstants.cryptoVersion,
      'scheme': CryptoConstants.schemeFileSigned1,
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
