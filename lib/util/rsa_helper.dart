import 'dart:typed_data';
import 'dart:math';
import 'package:pointycastle/asymmetric/api.dart';
import 'package:pointycastle/api.dart' as pc;
import 'package:pointycastle/export.dart';
import 'package:pointycastle/key_generators/rsa_key_generator.dart';
import 'package:encrypt/encrypt.dart';
import 'package:basic_utils/basic_utils.dart';

class RSAHelper {
  static pc.AsymmetricKeyPair<pc.PublicKey, pc.PrivateKey> generateKeyPair({int bitLength = 4096}) {
    final keyParams = RSAKeyGeneratorParameters(BigInt.parse('65537'), bitLength, 64);
    final secureRandom = _getSecureRandom();

    final rngParams = pc.ParametersWithRandom(keyParams, secureRandom);
    final generator = RSAKeyGenerator();
    generator.init(rngParams);

    return generator.generateKeyPair();
  }

  static pc.SecureRandom _getSecureRandom() {
    final secureRandom = FortunaRandom();
    final seedSource = Random.secure();
    final seeds = List<int>.generate(32, (_) => seedSource.nextInt(256));
    secureRandom.seed(pc.KeyParameter(Uint8List.fromList(seeds)));
    return secureRandom;
  }

  static String publicKeyToPem(RSAPublicKey publicKey) {
    return CryptoUtils.encodeRSAPublicKeyToPem(publicKey);
  }

  static String privateKeyToPem(RSAPrivateKey privateKey) {
    return CryptoUtils.encodeRSAPrivateKeyToPem(privateKey);
  }

  static RSAPublicKey publicKeyFromPem(String pem) {
    return CryptoUtils.rsaPublicKeyFromPem(pem);
  }

  static RSAPrivateKey privateKeyFromPem(String pem) {
    return CryptoUtils.rsaPrivateKeyFromPem(pem);
  }

  /// Encrypt text with public key
  static String encryptWithPublicKey(String plainText, RSAPublicKey publicKey) {
    final encrypter = Encrypter(RSA(publicKey: publicKey, encoding: RSAEncoding.PKCS1));
    return encrypter.encrypt(plainText).base64;
  }

  /// Decrypt text with private key
  static String decryptWithPrivateKey(String encrypted, RSAPrivateKey privateKey) {
    final encrypter = Encrypter(RSA(privateKey: privateKey, encoding: RSAEncoding.PKCS1));
    return encrypter.decrypt64(encrypted);
  }

  /// Encrypt raw bytes (for files/photos) with public key
  static String encryptBytesWithPublicKey(Uint8List data, RSAPublicKey publicKey) {
    final encrypter = Encrypter(RSA(publicKey: publicKey, encoding: RSAEncoding.PKCS1));
    return encrypter.encryptBytes(data).base64;
  }

  /// Decrypt raw bytes (for files/photos) with private key
  static Uint8List decryptBytesWithPrivateKey(Uint8List encryptedBytes, RSAPrivateKey privateKey) {
    final encrypter = Encrypter(RSA(privateKey: privateKey, encoding: RSAEncoding.PKCS1));
    final decryptedList = encrypter.decryptBytes(Encrypted(encryptedBytes));
    return Uint8List.fromList(decryptedList);
  }

}
