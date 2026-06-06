import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/util/group_crypto.dart';

void main() {
  test('encryptText and decryptText round-trip', () {
    final key = GroupCrypto.generateGroupKey();
    const plaintext = 'Hello group chat';

    final encrypted = GroupCrypto.encryptText(key, plaintext);
    final decrypted = GroupCrypto.decryptText(key, encrypted);

    expect(decrypted, plaintext);
  });

  test('encryptGroupFile and decryptGroupFile round-trip', () {
    final key = GroupCrypto.generateGroupKey();
    final bytes = Uint8List.fromList(List.generate(256, (i) => i % 256));

    final encrypted = GroupCrypto.encryptGroupFile(key, bytes);
    final decrypted = GroupCrypto.decryptGroupFile(key, encrypted);

    expect(decrypted, bytes);
  });

  test('control envelope JSON has expected shape', () {
    final key = GroupCrypto.generateGroupKey();
    final enc = GroupCrypto.encryptText(key, 'payload');
    final parsed = jsonDecode(enc) as Map<String, dynamic>;
    expect(parsed.containsKey('iv'), isTrue);
    expect(parsed.containsKey('ct'), isTrue);
  });
}
