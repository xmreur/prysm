import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as pkg;

import 'errors.dart';
import 'signing.dart';

/// A Prysm public identity as it appears on the wire: an Ed25519 signing key,
/// an X25519 agreement key, and the fingerprint over both.
///
/// Mirrors `lib/crypto/identity.dart` in the app byte-for-byte on purpose: a
/// relay whose fingerprint were computed differently could not be verified by
/// the app, and the app is the party that has to trust it.
class RelayIdentity {
  final Uint8List signPublic;
  final Uint8List agreePublic;
  final String fingerprint;

  const RelayIdentity({
    required this.signPublic,
    required this.agreePublic,
    required this.fingerprint,
  });

  static const String cryptoVersion = 'v2';

  /// Hex SHA-256 over `signPublic || agreePublic`.
  static String fingerprintOf(List<int> signPublic, List<int> agreePublic) =>
      pkg.sha256.convert([...signPublic, ...agreePublic]).toString();

  Map<String, dynamic> toJson() => {
        'crypto': cryptoVersion,
        'signPublic': base64Encode(signPublic),
        'agreePublic': base64Encode(agreePublic),
        'fingerprint': fingerprint,
      };

  String toJsonString() => jsonEncode(toJson());

  static RelayIdentity fromKeys({
    required List<int> signPublic,
    required List<int> agreePublic,
  }) =>
      RelayIdentity(
        signPublic: Uint8List.fromList(signPublic),
        agreePublic: Uint8List.fromList(agreePublic),
        fingerprint: fingerprintOf(signPublic, agreePublic),
      );

  /// Parses and **re-derives** the fingerprint, rejecting a mismatch: a claimed
  /// fingerprint is worth nothing, a computed one is worth everything.
  static RelayIdentity parse(Object? raw) {
    final Map<String, dynamic> json;
    if (raw is String) {
      try {
        json = jsonDecode(raw) as Map<String, dynamic>;
      } catch (_) {
        throw RelayError.badRequest('identity json is not an object');
      }
    } else if (raw is Map) {
      json = Map<String, dynamic>.from(raw);
    } else {
      throw RelayError.badRequest('identity json missing');
    }
    if (json['crypto'] != cryptoVersion) {
      throw RelayError.badRequest('unsupported identity crypto version');
    }
    final Uint8List signPublic;
    final Uint8List agreePublic;
    try {
      signPublic = base64Decode(json['signPublic'] as String);
      agreePublic = base64Decode(json['agreePublic'] as String);
    } catch (_) {
      throw RelayError.badRequest('signPublic/agreePublic must be base64');
    }
    if (signPublic.length != 32 || agreePublic.length != 32) {
      throw RelayError.badRequest('identity keys must be 32 bytes each');
    }
    final computed = fingerprintOf(signPublic, agreePublic);
    final claimed = json['fingerprint'];
    if (claimed is String && claimed.isNotEmpty && claimed != computed) {
      throw RelayError.badRequest('fingerprint does not match the public keys');
    }
    return RelayIdentity(
      signPublic: signPublic,
      agreePublic: agreePublic,
      fingerprint: RelayFields.fingerprint(computed),
    );
  }
}
