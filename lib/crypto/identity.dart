import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:crypto/crypto.dart' as dart_crypto;
import 'package:prysm/crypto/constants.dart';

/// Ed25519 signing + X25519 agreement identity.
class IdentityKeyPair {
  IdentityKeyPair({
    required this.signKeyPair,
    required this.agreeKeyPair,
  });

  final SimpleKeyPair signKeyPair;
  final SimpleKeyPair agreeKeyPair;

  static final Ed25519 _ed25519 = Ed25519();
  static final X25519 _x25519 = X25519();

  static Future<IdentityKeyPair> generate() async {
    final signKeyPair = await _ed25519.newKeyPair();
    final agreeKeyPair = await _x25519.newKeyPair();
    return IdentityKeyPair(
      signKeyPair: signKeyPair,
      agreeKeyPair: agreeKeyPair,
    );
  }

  Future<SimplePublicKey> get signPublicKey async =>
      await signKeyPair.extractPublicKey();

  Future<SimplePublicKey> get agreePublicKey async =>
      await agreeKeyPair.extractPublicKey();

  Future<Uint8List> signPublicKeyBytes() async {
    final pub = await signPublicKey;
    return Uint8List.fromList(pub.bytes);
  }

  Future<Uint8List> agreePublicKeyBytes() async {
    final pub = await agreePublicKey;
    return Uint8List.fromList(pub.bytes);
  }

  Future<Map<String, dynamic>> toPublicJson() async {
    final signBytes = await signPublicKeyBytes();
    final agreeBytes = await agreePublicKeyBytes();
    return {
      'crypto': CryptoConstants.cryptoVersion,
      'signPublic': base64Encode(signBytes),
      'agreePublic': base64Encode(agreeBytes),
      'fingerprint': fingerprintFromPublicKeys(signBytes, agreeBytes),
    };
  }

  static String fingerprintFromPublicKeys(
    Uint8List signPublic,
    Uint8List agreePublic,
  ) {
    final digest = dart_crypto.sha256.convert([...signPublic, ...agreePublic]);
    return digest.toString();
  }

  static String fingerprintFromPublicJson(Map<String, dynamic> json) {
    final sign = base64Decode(json['signPublic'] as String);
    final agree = base64Decode(json['agreePublic'] as String);
    return fingerprintFromPublicKeys(
      Uint8List.fromList(sign),
      Uint8List.fromList(agree),
    );
  }

  static IdentityPublicKeys parsePublicJson(Map<String, dynamic> json) {
    if (json['crypto'] != CryptoConstants.cryptoVersion) {
      throw FormatException('Unsupported identity crypto version');
    }
    final signBytes = base64Decode(json['signPublic'] as String);
    final agreeBytes = base64Decode(json['agreePublic'] as String);
    return IdentityPublicKeys(
      signPublic: SimplePublicKey(
        signBytes,
        type: KeyPairType.ed25519,
      ),
      agreePublic: SimplePublicKey(
        agreeBytes,
        type: KeyPairType.x25519,
      ),
      fingerprint: json['fingerprint'] as String? ??
          fingerprintFromPublicKeys(
            Uint8List.fromList(signBytes),
            Uint8List.fromList(agreeBytes),
          ),
    );
  }

  static IdentityPublicKeys? tryParsePublicJsonString(String? raw) {
    if (raw == null || raw.trim().isEmpty || raw == 'NONE') return null;
    final trimmed = raw.trimLeft();
    if (!trimmed.startsWith('{')) return null;
    try {
      final parsed = jsonDecode(raw);
      if (parsed is! Map<String, dynamic>) return null;
      return parsePublicJson(parsed);
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>> toPrivateJson() async {
    final signPrivate = await signKeyPair.extractPrivateKeyBytes();
    final agreePrivate = await agreeKeyPair.extractPrivateKeyBytes();
    final signPub = await signPublicKeyBytes();
    final agreePub = await agreePublicKeyBytes();
    return {
      'keystore': CryptoConstants.keystoreVersion,
      'signPrivate': base64Encode(signPrivate),
      'agreePrivate': base64Encode(agreePrivate),
      'signPublic': base64Encode(signPub),
      'agreePublic': base64Encode(agreePub),
    };
  }

  static Future<IdentityKeyPair> fromPrivateJson(
    Map<String, dynamic> json,
  ) async {
    if (json['keystore'] != CryptoConstants.keystoreVersion) {
      throw FormatException('Unsupported keystore version');
    }
    final signPrivate = base64Decode(json['signPrivate'] as String);
    final agreePrivate = base64Decode(json['agreePrivate'] as String);
    final signPublic = base64Decode(json['signPublic'] as String);
    final agreePublic = base64Decode(json['agreePublic'] as String);

    final signKeyPair = await _ed25519.newKeyPairFromSeed(signPrivate);
    final agreeKeyPair = await _x25519.newKeyPairFromSeed(agreePrivate);

    final derivedSignPub = await signKeyPair.extractPublicKey();
    final derivedAgreePub = await agreeKeyPair.extractPublicKey();
    if (!_bytesEqual(derivedSignPub.bytes, signPublic) ||
        !_bytesEqual(derivedAgreePub.bytes, agreePublic)) {
      throw FormatException('Identity key mismatch');
    }

    return IdentityKeyPair(
      signKeyPair: signKeyPair,
      agreeKeyPair: agreeKeyPair,
    );
  }

  static bool _bytesEqual(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  Future<Signature> sign(List<int> message) async {
    return _ed25519.sign(message, keyPair: signKeyPair);
  }

  static Future<bool> verify(
    List<int> message,
    Signature signature,
  ) async {
    return _ed25519.verify(message, signature: signature);
  }
}

class IdentityPublicKeys {
  const IdentityPublicKeys({
    required this.signPublic,
    required this.agreePublic,
    required this.fingerprint,
  });

  final SimplePublicKey signPublic;
  final SimplePublicKey agreePublic;
  final String fingerprint;

  Map<String, dynamic> toJson() => {
        'crypto': CryptoConstants.cryptoVersion,
        'signPublic': base64Encode(signPublic.bytes),
        'agreePublic': base64Encode(agreePublic.bytes),
        'fingerprint': fingerprint,
      };

  String toJsonString() => jsonEncode(toJson());
}
