/// The pairing link: one URI carrying the three values Pairing needs.
///
/// `prysm-relay://pair?onion=<56>.onion&fpr=<hex64>&token=<hex64>`
///
/// It is a provisioning artifact, not a wire message: the relay operator
/// prints it (as text and as a QR code) and the owner pastes or scans it
/// into the app, which fills the Pairing form and — because the link
/// carries the relay's Fingerprint — checks the manifest it fetches
/// against it before the human has to compare anything. The link is as
/// secret as the token it carries: single-use, expiring on the relay.
///
/// No expiry field: the relay is the authority on the token's lifetime, and
/// a copy of it in the link would only ever disagree.
library;

import 'errors.dart';
import 'signing.dart';

class RelayPairingLink {
  const RelayPairingLink({
    required this.onion,
    required this.fingerprint,
    required this.token,
  });

  static const String scheme = 'prysm-relay';
  static const String host = 'pair';

  /// The relay's v3 onion address.
  final String onion;

  /// The relay's Fingerprint, lowercase hex.
  final String fingerprint;

  /// A single-use setup/invite token, lowercase hex.
  final String token;

  /// True when [raw] looks like a pairing link (scheme + host), whatever the
  /// rest: the app uses it to decide whether pasted text is a link at all.
  static bool looksLike(String raw) {
    final t = raw.trim();
    return t.startsWith('$scheme://$host?') || t.startsWith('$scheme://$host/?');
  }

  /// Parses and validates; every field must be present and well-formed.
  /// Throws [RelayError] (`bad_request`) otherwise.
  static RelayPairingLink parse(String raw) {
    final Uri uri;
    try {
      uri = Uri.parse(raw.trim());
    } on FormatException catch (e) {
      throw RelayError.badRequest('pairing link is not a URI: ${e.message}');
    }
    if (uri.scheme != scheme || uri.host != host) {
      throw RelayError.badRequest(
        'pairing link must start with $scheme://$host',
      );
    }
    final q = uri.queryParameters;
    return RelayPairingLink(
      onion: RelayFields.onion(q['onion'], field: 'onion'),
      fingerprint: RelayFields.fingerprint(q['fpr'], field: 'fpr'),
      token: RelayFields.fingerprint(q['token'], field: 'token'),
    );
  }

  /// The canonical text form: fixed parameter order, nothing else.
  String encode() => '$scheme://$host?onion=$onion&fpr=$fingerprint&token=$token';

  @override
  String toString() => encode();
}
