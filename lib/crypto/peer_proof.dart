import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:prysm/crypto/identity.dart';

/// Ed25519 proof-of-identity for transport-level authentication.
///
/// Sync hints and WebSocket hellos carry a bare `senderId` JSON claim; a
/// claim proves nothing, so an attacker who learned a victim's contact list
/// could impersonate any contact. [PeerProof] lets the sender sign the claim
/// with its long-term identity key and lets the receiver verify it against
/// the identity it already knows for that onion.
class PeerProof {
  PeerProof._();

  static const String syncHintContext = 'prysm-sync-hint-1';
  static const String wsHelloContext = 'prysm-ws-hello-1';
  static const Duration maxSkew = Duration(minutes: 5);

  static final Ed25519 _ed25519 = Ed25519();

  /// Domain-separated, unambiguous: `` `<context>|<sender>|<receiver>|<timestampMs>` ``.
  ///
  /// The `|` separator is safe because onion addresses and decimal
  /// timestamps cannot contain it. The context prefix keeps a captured
  /// sync-hint signature from being replayed as a WS hello (and vice versa).
  static List<int> canonicalBytes({
    required String context,
    required String senderOnion,
    required String receiverOnion,
    required int timestampMs,
  }) {
    return utf8.encode('$context|$senderOnion|$receiverOnion|$timestampMs');
  }

  static Future<String> sign({
    required String context,
    required String senderOnion,
    required String receiverOnion,
    required int timestampMs,
    required IdentityKeyPair identity,
  }) async {
    final signature = await identity.sign(
      canonicalBytes(
        context: context,
        senderOnion: senderOnion,
        receiverOnion: receiverOnion,
        timestampMs: timestampMs,
      ),
    );
    return base64Encode(signature.bytes);
  }

  /// Returns `false` (never throws) when the base64 is malformed, the
  /// decoded signature is not exactly 64 bytes, the signature does not
  /// verify, or `|now - timestampMs|` exceeds [maxSkew]. The skew check runs
  /// before the expensive signature verification so a replay flood cannot
  /// force Ed25519 work.
  static Future<bool> verify({
    required String context,
    required String senderOnion,
    required String receiverOnion,
    required int timestampMs,
    required String signature,
    required IdentityPublicKeys peer,
    DateTime? now,
  }) async {
    final nowMs = (now ?? DateTime.now()).millisecondsSinceEpoch;
    if ((nowMs - timestampMs).abs() > maxSkew.inMilliseconds) {
      return false;
    }
    final List<int> sigBytes;
    try {
      sigBytes = base64Decode(signature);
    } on FormatException {
      return false;
    }
    if (sigBytes.length != 64) {
      return false;
    }
    try {
      return await _ed25519.verify(
        canonicalBytes(
          context: context,
          senderOnion: senderOnion,
          receiverOnion: receiverOnion,
          timestampMs: timestampMs,
        ),
        signature: Signature(sigBytes, publicKey: peer.signPublic),
      );
    } catch (_) {
      // Totality contract: a peer-supplied signature must never turn into an
      // exception here — callers treat `false` as a clean rejection.
      return false;
    }
  }

  /// Composition-time hook, not ambient global state: the outbound transport
  /// layer ([TransportProvider]) is constructed from a [TorManager] alone and
  /// has no path to a [KeyManager]; plumbing one through
  /// `TransportProvider.configure` → `WsConnectionManager` →
  /// `TorWebSocketClient` would touch a dozen call sites and every transport
  /// test. So the composition root sets this once (`AppComposition
  /// .wireTorConnected`), and transport code signs with whatever identity is
  /// live. The closure must return null (never throw) when the identity is
  /// unavailable — e.g. while the keystore is locked — and callers treat null
  /// as "cannot sign, skip".
  static IdentityKeyPair? Function()? localIdentity;
}
