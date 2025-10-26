import 'dart:typed_data';
import 'dart:math';
import 'package:encrypt/encrypt.dart';

class AESHelper {
  static Key generateAESKey({int length = 32}) {
    final random = Random.secure();
    final keyBytes = List<int>.generate(length, (_) => random.nextInt(256));
    return Key(Uint8List.fromList(keyBytes));
  }

  static IV generateIV({int length = 16}) {
    final random = Random.secure();
    final ivBytes = List<int>.generate(length, (_) => random.nextInt(256));
    return IV(Uint8List.fromList(ivBytes));
  }

  static Uint8List encryptBytes(Uint8List data, Key key, IV iv) {
    final encrypter = Encrypter(AES(key, mode: AESMode.cbc));
    final encrypted = encrypter.encryptBytes(data, iv: iv);
    return Uint8List.fromList(encrypted.bytes);
  }

  static Uint8List decryptBytes(Uint8List encryptedData, Key key, IV iv) {
    final encrypter = Encrypter(AES(key, mode: AESMode.cbc));
    final decrypted = encrypter.decryptBytes(Encrypted(encryptedData), iv: iv);
    return Uint8List.fromList(decrypted);
  }
}
