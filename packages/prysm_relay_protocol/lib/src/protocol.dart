import 'errors.dart';

/// Protocol-wide constants and the typed error vocabulary.
class RelayProtocol {
  RelayProtocol._();

  /// Exact protocol id. A request carrying anything else is rejected; there is
  /// no version negotiation in v1, only a flat refusal.
  static const String id = 'prysm-relay/1';

  static const String sealScheme = 'relay-sealed-1';
  static const String sealAlg = 'x25519-hkdf-aes256gcm';
  static const String cryptoVersion = 'v2';

  /// Domain separation: differs from the app's `hkdfInfoDhAead`, so a sealed
  /// blob can never be replayed into the 1:1 DM path.
  static const String sealHkdfInfo = 'prysm-relay-seal-1';

  static const String authContext = 'prysm-relay-auth-1';
  static const String pairContext = 'prysm-relay-pair-1';
  static const String contractContext = 'prysm-relay-contract-1';
  static const String manifestContext = 'prysm-relay-manifest-1';
  static const String advertContext = 'prysm-relay-advert-1';

  static const Duration maxSkew = Duration(seconds: 300);
  static const Duration replayWindow = Duration(seconds: 600);

  static const int depositAddressBytes = 32;
  static const int sealNonceBytes = 12;
  static const int aeadKeyBytes = 32;
  static const int x25519KeyBytes = 32;
  static const int ed25519SignatureBytes = 64;

  static const String headerOwner = 'x-prysm-owner';
  static const String headerTimestamp = 'x-prysm-timestamp';
  static const String headerSignature = 'x-prysm-signature';

  static const String pathManifest = '/relay/manifest';
  static const String pathPair = '/relay/pair';
  static const String pathMailbox = '/relay/mailbox';
  static const String pathDeposit = '/relay/deposit';
  static const String pathPickup = '/relay/pickup';
  static const String pathAck = '/relay/ack';
  static const String pathStatus = '/relay/status';
  static const String pathUnpair = '/relay/unpair';
}

/// Tenancy of a relay: a Private Relay serves a single identity.
enum RelayTenancy {
  private,
  public;

  static RelayTenancy parse(Object? raw) => switch (raw) {
        'private' => RelayTenancy.private,
        'public' => RelayTenancy.public,
        _ => throw RelayError.badRequest('unknown tenancy: $raw'),
      };

  String get wire => name;
}

/// How a relay admits new contracts.
enum RelayAdmission {
  closed,
  invite,
  open;

  static RelayAdmission parse(Object? raw) => switch (raw) {
        'closed' => RelayAdmission.closed,
        'invite' => RelayAdmission.invite,
        'open' => RelayAdmission.open,
        _ => throw RelayError.badRequest('unknown admission: $raw'),
      };

  String get wire => name;
}

/// The typed error vocabulary. `retryable` tells the sending client whether to
/// keep the message in its local pending queue and try again later, or to give
/// up on relay delivery for that message (it still waits for direct delivery).
class RelayErrorCode {
  RelayErrorCode._();

  static const String badRequest = 'bad_request';
  static const String badSignature = 'bad_signature';
  static const String notPaired = 'not_paired';
  static const String staleRequest = 'stale_request';
  static const String replayed = 'replayed';
  static const String mailboxUnknown = 'mailbox_unknown';
  static const String mailboxDisabled = 'mailbox_disabled';
  static const String itemTooLarge = 'item_too_large';
  static const String mailboxFull = 'mailbox_full';
  static const String tenantFull = 'tenant_full';
  static const String rateLimited = 'rate_limited';
  static const String admissionClosed = 'admission_closed';
  static const String badToken = 'bad_token';
  static const String notFound = 'not_found';
  static const String internal = 'internal';

  static const Map<String, int> _status = {
    badRequest: 400,
    badSignature: 403,
    notPaired: 403,
    staleRequest: 401,
    replayed: 409,
    mailboxUnknown: 404,
    mailboxDisabled: 403,
    itemTooLarge: 413,
    mailboxFull: 507,
    tenantFull: 507,
    rateLimited: 429,
    admissionClosed: 403,
    badToken: 403,
    notFound: 404,
    internal: 500,
  };

  static const Set<String> _retryable = {
    staleRequest,
    mailboxFull,
    tenantFull,
    rateLimited,
    internal,
  };

  static int httpStatus(String code) => _status[code] ?? 500;

  static bool isRetryable(String code) => _retryable.contains(code);
}
