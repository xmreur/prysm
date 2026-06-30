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
