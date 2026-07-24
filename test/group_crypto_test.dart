import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/crypto/group_crypto.dart';

void main() {
  test('group text round trip', () async {
    final key = GroupCryptoV2.generateGroupKey();
    const plaintext = 'hello group';
    final encrypted = await GroupCryptoV2.encryptText(key, plaintext);
    final decrypted = await GroupCryptoV2.decryptText(key, encrypted);
    expect(decrypted, plaintext);
  });

  test('group file round trip', () async {
    final key = GroupCryptoV2.generateGroupKey();
    final bytes = Uint8List.fromList([1, 2, 3, 4, 5]);
    final encrypted = await GroupCryptoV2.encryptGroupFile(key, bytes);
    final decrypted = await GroupCryptoV2.decryptGroupFile(key, encrypted);
    expect(decrypted, bytes);
  });
}
