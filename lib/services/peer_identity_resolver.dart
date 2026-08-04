import 'dart:convert';

import 'package:prysm/crypto/crypto.dart';
import 'package:prysm/transport/transport_provider.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/logging.dart';
import 'package:prysm/util/tor_runtime_gate.dart';

/// A peer identity fetched over Tor, plus the prekey bundle offered
/// alongside it (if any).
class ResolvedPeerIdentity {
  final IdentityPublicKeys identity;
  final PrekeyBundle? prekeyBundle;

  const ResolvedPeerIdentity(this.identity, this.prekeyBundle);
}

/// Fetches and persists a peer's identity (public keys + optional prekey
/// bundle) for 1:1 chat.
///
/// Extracted from [ChatService] (Fase 3.2): owns the DB lookup for a
/// cached identity and the Tor fetch/persist path. Which tier to try
/// first (explicit JSON, cache, network) and how to react per tier stays
/// with the caller, since `ChatService.initialize` and the
/// `processPendingForPeer`/`processGlobalPending` wake-hint paths
/// sequence those tiers slightly differently.
class PeerIdentityResolver {
  final String peerId;
  final KeyManager keyManager;
  final Future<String> Function(String peerId) _fetchProfile;
  final Future<String> Function(String peerId) _fetchPublic;

  /// [fetchProfile]/[fetchPublic] default to [TransportProvider]'s Tor
  /// helpers; tests inject fakes here instead of hitting the network.
  PeerIdentityResolver({
    required this.peerId,
    required this.keyManager,
    Future<String> Function(String peerId)? fetchProfile,
    Future<String> Function(String peerId)? fetchPublic,
  })  : _fetchProfile = fetchProfile ?? TransportProvider.getProfileOrFallback,
        _fetchPublic = fetchPublic ?? TransportProvider.getPublicOrFallback;

  /// The identity JSON cached in the local user store for [peerId], if any.
  Future<String?> getCachedIdentityJson() async {
    try {
      final user = await DBHelper.getUserById(peerId);
      return IdentityKeyPair.storedPeerIdentityRaw(
        user?['identityJson'] as String?,
        user?['publicKeyPem'] as String?,
      );
    } catch (_) {
      return null;
    }
  }

  /// Fetches the peer's identity (and prekey bundle, if offered) over Tor
  /// and persists it to the local user store. Returns null when the fetch
  /// fails or the transport is currently blocked.
  ///
  /// [onIdentityResolved], when given, fires as soon as an identity import
  /// succeeds -- *before* prekey parsing is attempted. This mirrors the
  /// pre-split monolith (`ChatService._fetchPeerIdentityOverTor`), which
  /// assigned `peerIdentity` immediately after import and only afterwards
  /// attempted the prekey parse: if parsing (and the plain-identity
  /// fallback) both then fail, the overall fetch still reports failure but
  /// the partially-resolved identity is exposed to the caller via the
  /// callback, matching the original side effect 1:1.
  Future<ResolvedPeerIdentity?> fetchOverTor({
    void Function(IdentityPublicKeys identity)? onIdentityResolved,
  }) async {
    if (TorRuntimeGate.blocked) return null;
    try {
      String? identityJson;
      late IdentityPublicKeys identity;
      PrekeyBundle? prekeyBundle;
      try {
        final profileBody = await _fetchProfile(peerId);
        final data = jsonDecode(profileBody) as Map<String, dynamic>;
        identityJson = IdentityKeyPair.storedPeerIdentityRaw(
          (data['identityJson'] as String?)?.trim(),
          (data['publicKeyPem'] as String?)?.trim(),
        );
        final prekeyRaw = data['prekeyBundle'];
        identity = keyManager.importPeerIdentity(identityJson!);
        onIdentityResolved?.call(identity);
        if (prekeyRaw is Map) {
          prekeyBundle = await PrekeyBundle.parseVerified(
            Map<String, dynamic>.from(prekeyRaw),
            identity,
          );
        }
      } catch (_) {
        identityJson = (await _fetchPublic(peerId)).trim();
        identity = keyManager.importPeerIdentity(identityJson);
        onIdentityResolved?.call(identity);
      }
      await _persist(identityJson);
      return ResolvedPeerIdentity(identity, prekeyBundle);
    } catch (e) {
      Logging.error('Failed to fetch peer identity: $e', 'PeerIdentityResolver');
      return null;
    }
  }

  Future<void> _persist(String identityJson) async {
    try {
      final existing = await DBHelper.getUserById(peerId);
      await DBHelper.insertOrUpdateUser({
        'id': peerId,
        'name': existing?['name'] ?? peerId,
        'avatarUrl': existing?['avatarUrl'] ?? '',
        'avatarBase64': existing?['avatarBase64'],
        'customName': existing?['customName'],
        'identityJson': identityJson,
        'publicKeyPem': identityJson,
      });
    } catch (e) {
      Logging.error('Failed to persist peer public key: $e', 'PeerIdentityResolver');
    }
  }
}
