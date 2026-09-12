/// Owner authentication per spec §3.9: the three headers,
/// [RelaySigning.authBytes], ±300 s skew, and a replay cache of signature
/// digests with a 600 s window (evicted, not unbounded).
library;

import 'dart:convert';

import 'package:prysm_relay_protocol/prysm_relay_protocol.dart';
import 'package:shelf/shelf.dart';

/// Seen signature digests. Entries older than the replay window are evicted on
/// every check, so a prober replaying old signatures cannot grow the map
/// without bound.
class RelayAuthCache {
  final Map<String, int> _seen = {};

  int get tracked => _seen.length;

  /// Returns true when [digestHex] was already seen inside the window (and
  /// records nothing); otherwise records it and returns false.
  bool checkAndAdd(String digestHex, int nowMs) {
    _seen.removeWhere(
      (_, seenAt) => nowMs - seenAt > RelayProtocol.replayWindow.inMilliseconds,
    );
    if (_seen.containsKey(digestHex)) return true;
    _seen[digestHex] = nowMs;
    return false;
  }
}

/// Verifies the three owner-auth headers against the tenant's stored signing
/// key. Returns the owner fingerprint, or throws [RelayError] (`not_paired`,
/// `stale_request`, `bad_signature`, `replayed`).
Future<String> authenticateOwner({
  required Request request,
  required List<int> bodyBytes,
  required String relayFingerprint,
  required List<int>? Function(String ownerFingerprint) lookupSignKey,
  required RelayAuthCache replays,
  required DateTime now,
}) async {
  final owner = request.headers[RelayProtocol.headerOwner];
  final tsRaw = request.headers[RelayProtocol.headerTimestamp];
  final sig = request.headers[RelayProtocol.headerSignature];
  if (owner == null || tsRaw == null || sig == null) {
    throw RelayError.badRequest('missing owner auth headers');
  }
  String ownerFpr;
  try {
    ownerFpr = RelayFields.fingerprint(owner, field: 'X-Prysm-Owner');
  } catch (_) {
    // Malformed is unknown.
    throw const RelayError(RelayErrorCode.notPaired, 'owner is not paired');
  }
  final timestampMs = int.tryParse(tsRaw);
  if (timestampMs == null || timestampMs <= 0) {
    throw RelayError.badRequest('X-Prysm-Timestamp must be epoch milliseconds');
  }
  final signKey = lookupSignKey(ownerFpr);
  if (signKey == null) {
    throw const RelayError(RelayErrorCode.notPaired, 'owner is not paired');
  }
  if (!RelaySigning.freshTimestamp(timestampMs, now: now)) {
    throw const RelayError(
      RelayErrorCode.staleRequest,
      'timestamp outside the accepted clock skew',
    );
  }
  final bodyHash = RelaySigning.sha256Hex(bodyBytes);
  final ok = await RelaySigning.verify(
    message: RelaySigning.authBytes(
      relayFingerprint: relayFingerprint,
      ownerFingerprint: ownerFpr,
      method: request.method,
      path: request.requestedUri.path,
      timestampMs: timestampMs,
      bodySha256Hex: bodyHash,
    ),
    signatureB64: sig,
    ed25519PublicKey: signKey,
  );
  if (!ok) {
    throw const RelayError(RelayErrorCode.badSignature, 'bad owner signature');
  }
  List<int> sigBytes;
  try {
    sigBytes = base64Decode(sig);
  } catch (_) {
    throw const RelayError(RelayErrorCode.badSignature, 'bad owner signature');
  }
  final digest = RelaySigning.sha256Hex(sigBytes);
  if (replays.checkAndAdd(digest, now.millisecondsSinceEpoch)) {
    throw const RelayError(RelayErrorCode.replayed, 'signature already used');
  }
  return ownerFpr;
}
