import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'rsa_helper.dart';
import 'package:pointycastle/asymmetric/api.dart';

class KeyManager {
  static const String _privateKeyStorageKey = 'PRIVATE_KEY';
  static const String _publicKeyStorageKey = 'PUBLIC_KEY';
  static final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();

  RSAPublicKey? _publicKey;
  RSAPrivateKey? _privateKey;

  Future<void> initKeys() async {
    String? privatePem = await _secureStorage.read(key: _privateKeyStorageKey);
    String? publicPem = await _secureStorage.read(key: _publicKeyStorageKey);

    if (privatePem != null && publicPem != null) {
      _privateKey = RSAHelper.privateKeyFromPem(privatePem);
      _publicKey = RSAHelper.publicKeyFromPem(publicPem);
    } else {
      final keyPair = RSAHelper.generateKeyPair();
      _privateKey = keyPair.privateKey as RSAPrivateKey?;
      _publicKey = keyPair.publicKey as RSAPublicKey?;

      await _secureStorage.write(key: _privateKeyStorageKey, value: RSAHelper.privateKeyToPem(_privateKey!));
      await _secureStorage.write(key: _publicKeyStorageKey, value: RSAHelper.publicKeyToPem(_publicKey!));
    }
  }

  RSAPublicKey get publicKey {
    if (_publicKey == null) throw Exception("Keys not initialized. Call initKeys() first.");
    return _publicKey!;
  }

  RSAPrivateKey get privateKey {
    if (_privateKey == null) throw Exception("Keys not initialized. Call initKeys() first.");
    return _privateKey!;
  }

  String get publicKeyPem => RSAHelper.publicKeyToPem(publicKey);

  /// Encrypt text for peer
  String encryptForPeer(String message, RSAPublicKey peerPublicKey) {
    return RSAHelper.encryptWithPublicKey(message, peerPublicKey);
  }

  /// Encrypt raw bytes for peer
  String encryptBytesForPeer(Uint8List data, RSAPublicKey peerPublicKey) {
    return RSAHelper.encryptBytesWithPublicKey(data, peerPublicKey);
  }

  /// Encrypt text for self
  String encryptForSelf(String message) {
    return RSAHelper.encryptWithPublicKey(message, publicKey);
  }

  /// Encrypt raw bytes for self
  String encryptBytesForSelf(Uint8List data) {
    return RSAHelper.encryptBytesWithPublicKey(data, publicKey);
  }

  /// Decrypt text message
  String decryptMessage(String encrypted) {
    return RSAHelper.decryptWithPrivateKey(encrypted, privateKey);
  }

  /// Decrypt my text message
  String decryptMyMessage(String encryptedMessage) {
    return RSAHelper.decryptWithPrivateKey(encryptedMessage, privateKey);
  }

  /// Decrypt bytes (files/photos)
  Uint8List decryptBytes(String base64Encrypted) {
    final bytes = base64Decode(base64Encrypted);
    return RSAHelper.decryptBytesWithPrivateKey(bytes, privateKey);
  }

  Uint8List decryptMyMessageBytes(String base64Encrypted) {
    return decryptBytes(base64Encrypted);
  }

  RSAPublicKey importPeerPublicKey(String pem) {
    return RSAHelper.publicKeyFromPem(pem);
  }
}
