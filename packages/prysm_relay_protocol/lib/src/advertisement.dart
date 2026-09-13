import 'errors.dart';
import 'signing.dart';

/// One relay an owner is reachable through, as published to a single contact.
///
/// [deposit] is that contact's own mailbox address: nobody else learns it, and
/// revoking the contact is deleting it.
class RelayEndpoint {
  final String onion;
  final String deposit;
  final int maxItemBytes;
  final int blockSize;

  const RelayEndpoint({
    required this.onion,
    required this.deposit,
    required this.maxItemBytes,
    this.blockSize = 0,
  });

  Map<String, dynamic> toJson() => {
        'onion': onion,
        'deposit': deposit,
        'maxItemBytes': maxItemBytes,
        'blockSize': blockSize,
      };

  static RelayEndpoint fromJson(Map<String, dynamic> json) {
    final maxItemBytes = json['maxItemBytes'];
    if (maxItemBytes is! int || maxItemBytes <= 0) {
      throw RelayError.badRequest('maxItemBytes must be a positive int');
    }
    final blockSize = json['blockSize'];
    return RelayEndpoint(
      onion: RelayFields.onion(json['onion'], field: 'relay onion'),
      deposit: RelayFields.depositAddress(json['deposit']),
      maxItemBytes: maxItemBytes,
      blockSize: blockSize is int && blockSize >= 0 ? blockSize : 0,
    );
  }

  /// Every field of the endpoint, in wire order: a signature that covered only
  /// the address left `maxItemBytes` and `blockSize` editable by anything that
  /// handles the profile document, and those two decide whether the sender
  /// relays a message at all and how it is padded.
  String get signingPart => '$onion|$deposit|$maxItemBytes|$blockSize';
}

/// The `relay` block an owner publishes inside its per-requester `/profile`
/// answer. Signed by the owner's identity key so that a **cached** copy stays
/// verifiable — which is the whole point, since it is used exactly when the
/// owner is unreachable.
class RelayAdvertisement {
  static const int currentVersion = 1;

  final int version;
  final int issuedAt;
  final int expiresAt;
  final List<RelayEndpoint> relays;
  final String? sig;

  const RelayAdvertisement({
    required this.issuedAt,
    required this.expiresAt,
    required this.relays,
    this.version = currentVersion,
    this.sig,
  });

  bool expiredAt(DateTime now) => now.millisecondsSinceEpoch >= expiresAt;

  bool get isEmpty => relays.isEmpty;

  /// The relay a v1 client uses. The list is ordered and may hold more (the
  /// wire is ready for redundancy), but v1 deposits at the first entry only.
  RelayEndpoint? get preferred => relays.isEmpty ? null : relays.first;

  Map<String, dynamic> toJson() => {
        'v': version,
        'issuedAt': issuedAt,
        'expiresAt': expiresAt,
        'relays': relays.map((r) => r.toJson()).toList(),
        if (sig != null) 'sig': sig,
      };

  RelayAdvertisement withSignature(String signature) => RelayAdvertisement(
        issuedAt: issuedAt,
        expiresAt: expiresAt,
        relays: relays,
        version: version,
        sig: signature,
      );

  List<int> signingBytes(String ownerFingerprint) =>
      RelaySigning.advertisementBytes(
        ownerFingerprint: ownerFingerprint,
        issuedAt: issuedAt,
        expiresAt: expiresAt,
        relayParts: relays.map((r) => r.signingPart).toList(),
      );

  static RelayAdvertisement fromJson(Map<String, dynamic> json) {
    final version = json['v'];
    if (version is! int || version <= 0) {
      throw RelayError.badRequest('advertisement v must be a positive int');
    }
    final raw = json['relays'];
    if (raw is! List) {
      throw RelayError.badRequest('relays must be a list');
    }
    return RelayAdvertisement(
      version: version,
      issuedAt: RelayFields.timestamp(json['issuedAt'], field: 'issuedAt'),
      expiresAt: RelayFields.timestamp(json['expiresAt'], field: 'expiresAt'),
      relays: raw
          .map((e) => RelayEndpoint.fromJson(
                RelayFields.object(e, field: 'relays[]'),
              ))
          .toList(),
      sig: json['sig'] as String?,
    );
  }

  /// Verifies the owner's signature. A sender MUST call this before depositing:
  /// the advertisement usually comes from a local cache, not from a live fetch.
  Future<bool> verify({
    required String ownerFingerprint,
    required List<int> ownerSignPublicKey,
  }) async {
    final signature = sig;
    if (signature == null) return false;
    if (version != currentVersion) return false;
    return RelaySigning.verify(
      message: signingBytes(ownerFingerprint),
      signatureB64: signature,
      ed25519PublicKey: ownerSignPublicKey,
    );
  }
}
