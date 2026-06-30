import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/util/group_crypto.dart';

void main() {
  test('group text round trip', () async {
    final key = GroupCrypto.generateGroupKey();
    const plaintext = 'hello group';
    final encrypted = await GroupCrypto.encryptText(key, plaintext);
    final decrypted = await GroupCrypto.decryptText(key, encrypted);
    expect(decrypted, plaintext);
  });

  test('group file round trip', () async {
    final key = GroupCrypto.generateGroupKey();
    final bytes = Uint8List.fromList([1, 2, 3, 4, 5]);
    final encrypted = await GroupCrypto.encryptGroupFile(key, bytes);
    final decrypted = await GroupCrypto.decryptGroupFile(key, encrypted);
    expect(decrypted, bytes);
  });
}
