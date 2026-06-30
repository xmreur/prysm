import 'package:prysm/crypto/wire.dart';
import 'package:prysm/util/key_manager.dart';

Future<String?> decryptTextFileHybrid(
  String encryptedJson,
  KeyManager keyManager,
) async {
  if (!encryptedJson.trimLeft().startsWith('{')) return null;
  try {
    return await keyManager.decryptMessage(encryptedJson);
  } catch (_) {
    return null;
  }
}

Future<List<int>> decryptFileHybrid(
  String encryptedJson,
  KeyManager keyManager,
) async {
  final bytes = await CryptoWire.decryptFile(encryptedJson, keyManager.identity);
  return bytes;
}
