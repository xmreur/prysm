import 'package:prysm/crypto/identity.dart';
import 'package:prysm/services/peer_identity_resolver.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/util/key_manager.dart';

Future<IdentityPublicKeys?> loadPeerIdentityFromDb(
  KeyManager keyManager,
  String peerId,
) async {
  final user = await DBHelper.getUserById(peerId);
  return keyManager.tryImportStoredPeerIdentity(
    identityJson: user?['identityJson'] as String?,
    publicKeyPem: user?['publicKeyPem'] as String?,
  );
}

/// Resolves peer identity for ingress: local DB first, then awaited Tor fetch.
Future<IdentityPublicKeys?> resolvePeerIdentityForIngress(
  KeyManager keyManager,
  String peerId, {
  required Future<ResolvedPeerIdentity?> Function() fetchOverTor,
}) async {
  final cached = await loadPeerIdentityFromDb(keyManager, peerId);
  if (cached != null) return cached;
  final resolved = await fetchOverTor();
  return resolved?.identity;
}

/// Resolves the public keys that signed a group message.
///
/// The local user's own row in `users` carries a placeholder identity, so for
/// [localUserId] the keystore identity — the key that actually produced the
/// signature — is authoritative instead of the peer store.
Future<IdentityPublicKeys?> loadGroupSenderIdentity(
  KeyManager keyManager,
  String senderId, {
  required String localUserId,
}) async {
  if (senderId != localUserId) {
    return loadPeerIdentityFromDb(keyManager, senderId);
  }
  try {
    final identity = keyManager.identity;
    final publicJson = await identity.toPublicJson();
    return IdentityPublicKeys(
      signPublic: await identity.signPublicKey,
      agreePublic: await identity.agreePublicKey,
      fingerprint: IdentityKeyPair.fingerprintFromPublicJson(publicJson),
    );
  } catch (_) {
    return null;
  }
}
