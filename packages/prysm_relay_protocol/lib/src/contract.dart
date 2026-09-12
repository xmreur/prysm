import 'canonical.dart';
import 'errors.dart';
import 'identity.dart';
import 'limits.dart';
import 'protocol.dart';
import 'signing.dart';

/// What a relay publishes about itself, signed, so a user can see who they are
/// pairing with and what is promised *before* a Contract exists.
class RelayManifest {
  /// The relay's public identity JSON. Without it the signature below is
  /// unverifiable: a fingerprint alone is a claim, not a key.
  final String relayIdentityJson;
  final String relayFingerprint;
  final String relayOnion;
  final RelayTenancy tenancy;
  final RelayAdmission admission;
  final RelayLimits limits;
  final String terms;
  final String software;
  final int issuedAt;
  final String? sig;

  const RelayManifest({
    required this.relayIdentityJson,
    required this.relayFingerprint,
    required this.relayOnion,
    required this.tenancy,
    required this.admission,
    required this.limits,
    required this.software,
    required this.issuedAt,
    this.terms = '',
    this.sig,
  });

  Map<String, dynamic> toJson() => {
        'protocol': RelayProtocol.id,
        'relayIdentityJson': relayIdentityJson,
        'relayFingerprint': relayFingerprint,
        'relayOnion': relayOnion,
        'tenancy': tenancy.wire,
        'admission': admission.wire,
        'limits': limits.toJson(),
        'terms': terms,
        'software': software,
        'issuedAt': issuedAt,
        if (sig != null) 'sig': sig,
      };

  RelayManifest withSignature(String signature) => RelayManifest(
        relayIdentityJson: relayIdentityJson,
        relayFingerprint: relayFingerprint,
        relayOnion: relayOnion,
        tenancy: tenancy,
        admission: admission,
        limits: limits,
        software: software,
        issuedAt: issuedAt,
        terms: terms,
        sig: signature,
      );

  List<int> signingBytes() => RelaySigning.manifestBytes(toJson());

  static RelayManifest fromJson(Map<String, dynamic> json) {
    RelayFields.requireProtocol(json['protocol']);
    final identity = RelayIdentity.parse(json['relayIdentityJson']);
    final claimed = RelayFields.fingerprint(
      json['relayFingerprint'],
      field: 'relayFingerprint',
    );
    if (claimed != identity.fingerprint) {
      throw RelayError.badRequest(
        'relayFingerprint does not match relayIdentityJson',
      );
    }
    return RelayManifest(
      relayIdentityJson: json['relayIdentityJson'] as String,
      relayFingerprint:
          RelayFields.fingerprint(json['relayFingerprint'], field: 'relayFingerprint'),
      relayOnion: RelayFields.onion(json['relayOnion'], field: 'relayOnion'),
      tenancy: RelayTenancy.parse(json['tenancy']),
      admission: RelayAdmission.parse(json['admission']),
      limits: RelayLimits.fromJson(
        RelayFields.object(json['limits'], field: 'limits'),
      ),
      terms: json['terms'] is String ? json['terms'] as String : '',
      software: json['software'] is String ? json['software'] as String : 'unknown',
      issuedAt: RelayFields.timestamp(json['issuedAt'], field: 'issuedAt'),
      sig: json['sig'] as String?,
    );
  }

  /// The relay's parsed identity. Throws [RelayError] when the embedded JSON
  /// and the advertised fingerprint disagree.
  RelayIdentity get identity => RelayIdentity.parse(relayIdentityJson);

  /// Verifies the manifest signature against the relay's Ed25519 public key.
  Future<bool> verify(List<int> relaySignPublicKey) async {
    final signature = sig;
    if (signature == null) return false;
    return RelaySigning.verify(
      message: signingBytes(),
      signatureB64: signature,
      ed25519PublicKey: relaySignPublicKey,
    );
  }

  /// Self-contained check: the embedded identity signs this manifest, and its
  /// fingerprint is the one advertised. This is what a client runs before
  /// showing the user anything.
  Future<bool> verifySelf() async {
    final RelayIdentity parsed;
    try {
      parsed = identity;
    } on RelayError {
      return false;
    }
    if (parsed.fingerprint != relayFingerprint) return false;
    return verify(parsed.signPublic);
  }
}

/// The signed agreement between one owner and one relay.
class RelayContract {
  final int version;
  final String relayFingerprint;
  final String relayOnion;
  final String ownerFingerprint;
  final String ownerOnion;
  final RelayTenancy tenancy;
  final RelayLimits limits;

  /// Only `reject` exists in v1: a full mailbox refuses the new deposit rather
  /// than dropping the oldest one, because losing the newest message is
  /// visible to its sender while losing the oldest is visible to nobody.
  final String overflow;
  final int issuedAt;
  final int? expiresAt;
  final String? sig;

  const RelayContract({
    required this.version,
    required this.relayFingerprint,
    required this.relayOnion,
    required this.ownerFingerprint,
    required this.ownerOnion,
    required this.tenancy,
    required this.limits,
    required this.issuedAt,
    this.overflow = 'reject',
    this.expiresAt,
    this.sig,
  });

  bool get expired {
    final deadline = expiresAt;
    if (deadline == null) return false;
    return DateTime.now().millisecondsSinceEpoch >= deadline;
  }

  Map<String, dynamic> toJson() => {
        'protocol': RelayProtocol.id,
        'version': version,
        'relayFingerprint': relayFingerprint,
        'relayOnion': relayOnion,
        'ownerFingerprint': ownerFingerprint,
        'ownerOnion': ownerOnion,
        'tenancy': tenancy.wire,
        'limits': limits.toJson(),
        'overflow': overflow,
        'issuedAt': issuedAt,
        'expiresAt': expiresAt,
        if (sig != null) 'sig': sig,
      };

  RelayContract withSignature(String signature) => RelayContract(
        version: version,
        relayFingerprint: relayFingerprint,
        relayOnion: relayOnion,
        ownerFingerprint: ownerFingerprint,
        ownerOnion: ownerOnion,
        tenancy: tenancy,
        limits: limits,
        issuedAt: issuedAt,
        overflow: overflow,
        expiresAt: expiresAt,
        sig: signature,
      );

  List<int> signingBytes() => RelaySigning.contractBytes(toJson());

  static RelayContract fromJson(Map<String, dynamic> json) {
    RelayFields.requireProtocol(json['protocol']);
    final version = json['version'];
    if (version is! int || version <= 0) {
      throw RelayError.badRequest('version must be a positive int');
    }
    final expires = json['expiresAt'];
    if (expires != null && (expires is! int || expires <= 0)) {
      throw RelayError.badRequest('expiresAt must be epoch ms or null');
    }
    return RelayContract(
      version: version,
      relayFingerprint: RelayFields.fingerprint(
        json['relayFingerprint'],
        field: 'relayFingerprint',
      ),
      relayOnion: RelayFields.onion(json['relayOnion'], field: 'relayOnion'),
      ownerFingerprint: RelayFields.fingerprint(
        json['ownerFingerprint'],
        field: 'ownerFingerprint',
      ),
      ownerOnion: RelayFields.onion(json['ownerOnion'], field: 'ownerOnion'),
      tenancy: RelayTenancy.parse(json['tenancy']),
      limits: RelayLimits.fromJson(
        RelayFields.object(json['limits'], field: 'limits'),
      ),
      overflow: json['overflow'] is String ? json['overflow'] as String : 'reject',
      issuedAt: RelayFields.timestamp(json['issuedAt'], field: 'issuedAt'),
      expiresAt: expires as int?,
      sig: json['sig'] as String?,
    );
  }

  Future<bool> verify(List<int> relaySignPublicKey) async {
    final signature = sig;
    if (signature == null) return false;
    return RelaySigning.verify(
      message: signingBytes(),
      signatureB64: signature,
      ed25519PublicKey: relaySignPublicKey,
    );
  }

  /// Canonical form used for local storage and comparison.
  String encode() => canonicalJson(toJson());
}

/// A client's pairing request: identity, onion, the limits it would like, and
/// a signature binding all of it to a single-use token.
class RelayPairRequest {
  final String token;
  final String ownerIdentityJson;
  final String ownerOnion;
  final Map<String, dynamic> requested;
  final int timestamp;
  final String sig;

  const RelayPairRequest({
    required this.token,
    required this.ownerIdentityJson,
    required this.ownerOnion,
    required this.timestamp,
    required this.sig,
    this.requested = const {},
  });

  Map<String, dynamic> toJson() => {
        'protocol': RelayProtocol.id,
        'token': token,
        'ownerIdentityJson': ownerIdentityJson,
        'ownerOnion': ownerOnion,
        'requested': requested,
        'timestamp': timestamp,
        'sig': sig,
      };

  static RelayPairRequest fromJson(Map<String, dynamic> json) {
    RelayFields.requireProtocol(json['protocol']);
    final requested = json['requested'];
    return RelayPairRequest(
      token: RelayFields.text(json['token'], field: 'token', maxBytes: 128),
      ownerIdentityJson: RelayFields.text(
        json['ownerIdentityJson'],
        field: 'ownerIdentityJson',
        maxBytes: 8192,
      ),
      ownerOnion: RelayFields.onion(json['ownerOnion'], field: 'ownerOnion'),
      requested: requested is Map ? Map<String, dynamic>.from(requested) : const {},
      timestamp: RelayFields.timestamp(json['timestamp']),
      sig: RelayFields.text(json['sig'], field: 'sig', maxBytes: 256),
    );
  }
}
