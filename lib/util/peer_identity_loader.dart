import 'package:prysm/crypto/identity.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/util/key_manager.dart';

Future<IdentityPublicKeys?> loadPeerIdentityFromDb(
  KeyManager keyManager,
  String peerId,
) async {
  final user = await DBHelper.getUserById(peerId);
  final json = (user?['identityJson'] as String?) ??
      (user?['publicKeyPem'] as String?);
  if (json == null || json.isEmpty) return null;
  try {
    return keyManager.importPeerIdentity(json);
  } catch (_) {
    return null;
  }
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
