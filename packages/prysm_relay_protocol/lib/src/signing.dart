import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as pkg;
import 'package:cryptography/cryptography.dart';

import 'canonical.dart';
import 'errors.dart';
import 'protocol.dart';

/// Every byte string this protocol signs, built in exactly one place.
///
/// Two rules make the scheme safe to extend: every payload starts with its own
/// context string (so a signature from one endpoint cannot be replayed into
/// another), and structured payloads are signed over [canonicalJson] (so map
/// ordering cannot change the bytes).
class RelaySigning {
  RelaySigning._();

  static final Ed25519 _ed25519 = Ed25519();

  static String sha256Hex(List<int> bytes) =>
      pkg.sha256.convert(bytes).toString();

  /// Owner authentication for every authenticated endpoint.
  static List<int> authBytes({
    required String relayFingerprint,
    required String ownerFingerprint,
    required String method,
    required String path,
    required int timestampMs,
    required String bodySha256Hex,
  }) =>
      utf8.encode('${RelayProtocol.authContext}|$relayFingerprint|'
          '$ownerFingerprint|${method.toUpperCase()} $path|$timestampMs|$bodySha256Hex');

  static List<int> pairBytes({
    required String relayFingerprint,
    required String ownerFingerprint,
    required String token,
    required int timestampMs,
  }) =>
      utf8.encode('${RelayProtocol.pairContext}|$relayFingerprint|'
          '$ownerFingerprint|$token|$timestampMs');

  static List<int> contractBytes(Map<String, dynamic> contractJson) =>
      utf8.encode('${RelayProtocol.contractContext}|'
          '${canonicalJson(withoutSignature(contractJson))}');

  static List<int> manifestBytes(Map<String, dynamic> manifestJson) =>
      utf8.encode('${RelayProtocol.manifestContext}|'
          '${canonicalJson(withoutSignature(manifestJson))}');

  /// The advertisement is signed field-by-field rather than as canonical JSON
  /// because it is published inside somebody else's document (`/profile`), and
  /// an intermediary that re-serialises that document must not break it.
  static List<int> advertisementBytes({
    required String ownerFingerprint,
    required int issuedAt,
    required int expiresAt,
    required List<String> relayParts,
  }) =>
      utf8.encode('${RelayProtocol.advertContext}|$ownerFingerprint|'
          '$issuedAt|$expiresAt|${relayParts.join('|')}');

  static Future<String> sign(List<int> message, KeyPair signingKeyPair) async {
    final signature = await _ed25519.sign(message, keyPair: signingKeyPair);
    return base64Encode(signature.bytes);
  }

  static Future<bool> verify({
    required List<int> message,
    required String signatureB64,
    required List<int> ed25519PublicKey,
  }) async {
    final Uint8List raw;
    try {
      raw = base64Decode(signatureB64);
    } on FormatException {
      return false;
    }
    if (raw.length != RelayProtocol.ed25519SignatureBytes) return false;
    if (ed25519PublicKey.length != 32) return false;
    return _ed25519.verify(
      message,
      signature: Signature(
        raw,
        publicKey: SimplePublicKey(ed25519PublicKey, type: KeyPairType.ed25519),
      ),
    );
  }

  /// True when [timestampMs] is inside [RelayProtocol.maxSkew] of [now].
  static bool freshTimestamp(int timestampMs, {DateTime? now}) {
    final current = (now ?? DateTime.now()).millisecondsSinceEpoch;
    final delta = (current - timestampMs).abs();
    return delta <= RelayProtocol.maxSkew.inMilliseconds;
  }

  static void requireFresh(int timestampMs, {DateTime? now}) {
    if (!freshTimestamp(timestampMs, now: now)) {
      throw const RelayError(
        RelayErrorCode.staleRequest,
        'timestamp outside the accepted clock skew',
      );
    }
  }
}

/// Validates the shapes this protocol repeats everywhere.
class RelayFields {
  RelayFields._();

  static final RegExp _hex64 = RegExp(r'^[0-9a-f]{64}$');
  static final RegExp _onion = RegExp(r'^[a-z2-7]{56}\.onion$');

  static String depositAddress(Object? raw, {String field = 'deposit'}) {
    if (raw is! String || !_hex64.hasMatch(raw)) {
      throw RelayError.badRequest('$field must be 64 lowercase hex chars');
    }
    return raw;
  }

  static String fingerprint(Object? raw, {String field = 'fingerprint'}) {
    if (raw is! String || !_hex64.hasMatch(raw)) {
      throw RelayError.badRequest('$field must be a 64-char hex fingerprint');
    }
    return raw;
  }

  static String onion(Object? raw, {String field = 'onion'}) {
    if (raw is! String || !_onion.hasMatch(raw)) {
      throw RelayError.badRequest('$field must be a v3 .onion address');
    }
    return raw;
  }

  static bool isOnion(String raw) => _onion.hasMatch(raw);

  static int timestamp(Object? raw, {String field = 'timestamp'}) {
    if (raw is! int || raw <= 0) {
      throw RelayError.badRequest('$field must be epoch milliseconds');
    }
    return raw;
  }

  static String text(Object? raw, {required String field, int maxBytes = 4096}) {
    if (raw is! String || raw.isEmpty) {
      throw RelayError.badRequest('$field must be a non-empty string');
    }
    if (utf8.encode(raw).length > maxBytes) {
      throw RelayError.badRequest('$field exceeds $maxBytes bytes');
    }
    return raw;
  }

  static Map<String, dynamic> object(Object? raw, {required String field}) {
    if (raw is! Map) {
      throw RelayError.badRequest('$field must be an object');
    }
    return Map<String, dynamic>.from(raw);
  }

  static void requireProtocol(Object? raw) {
    if (raw != RelayProtocol.id) {
      throw RelayError.badRequest(
        'protocol must be ${RelayProtocol.id}, got $raw',
      );
    }
  }
}
