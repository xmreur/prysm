import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:prysm/crypto/aead.dart';
import 'package:prysm/crypto/constants.dart';
import 'package:prysm/crypto/kdf.dart';

/// Simplified Double Ratchet session for 1:1 chats (Phase 2).
class RatchetSession {
  RatchetSession({
    required this.rootKey,
    required this.sendingChainKey,
    required this.receivingChainKey,
    required this.sendCounter,
    required this.recvCounter,
  });

  List<int> rootKey;
  List<int> sendingChainKey;
  List<int> receivingChainKey;
  int sendCounter;
  int recvCounter;

  static Future<RatchetSession> initializeAsInitiator(
    Uint8List sharedMaterial,
  ) async {
    final rootBytes = await _deriveRoot(sharedMaterial);
    final sendChain = await CryptoKdf.hkdf(
      sharedSecret: rootBytes,
      info: utf8.encode('${CryptoConstants.hkdfInfoRatchet}/send'),
    );
    final recvChain = await CryptoKdf.hkdf(
      sharedSecret: rootBytes,
      info: utf8.encode('${CryptoConstants.hkdfInfoRatchet}/recv'),
    );
    return RatchetSession(
      rootKey: rootBytes,
      sendingChainKey: await sendChain.extractBytes(),
      receivingChainKey: await recvChain.extractBytes(),
      sendCounter: 0,
      recvCounter: -1,
    );
  }

  static Future<RatchetSession> initializeAsResponder(
    Uint8List sharedMaterial,
  ) async {
    final rootBytes = await _deriveRoot(sharedMaterial);
    final sendChain = await CryptoKdf.hkdf(
      sharedSecret: rootBytes,
      info: utf8.encode('${CryptoConstants.hkdfInfoRatchet}/recv'),
    );
    final recvChain = await CryptoKdf.hkdf(
      sharedSecret: rootBytes,
      info: utf8.encode('${CryptoConstants.hkdfInfoRatchet}/send'),
    );
    return RatchetSession(
      rootKey: rootBytes,
      sendingChainKey: await sendChain.extractBytes(),
      receivingChainKey: await recvChain.extractBytes(),
      sendCounter: 0,
      recvCounter: -1,
    );
  }

  static Future<List<int>> _deriveRoot(Uint8List sharedMaterial) async {
    final root = await CryptoKdf.hkdf(
      sharedSecret: sharedMaterial,
      info: utf8.encode('${CryptoConstants.hkdfInfoRatchet}/root'),
      salt: Uint8List.fromList(utf8.encode('prysm/ratchet/root-salt')),
    );
    return await root.extractBytes();
  }

  Future<({String wire, Map<String, dynamic> handshake})> encryptMessage(
    Uint8List plaintext,
  ) async {
    final messageKey = await _nextSendKey();
    final aeadKey = await CryptoAead.secretKeyFromBytes(
      Uint8List.fromList(messageKey),
    );
    final enc = await CryptoAead.encryptAesGcm(plaintext, key: aeadKey);
    final wire = jsonEncode({
      'crypto': CryptoConstants.cryptoVersion,
      'scheme': CryptoConstants.schemeRatchet1,
      'nonce': base64Encode(enc.nonce),
      'ciphertext': base64Encode(enc.ciphertext),
      'counter': sendCounter - 1,
    });
    return (wire: wire, handshake: <String, dynamic>{});
  }

  Future<Uint8List> decryptMessage(String wire) async {
    final envelope = jsonDecode(wire) as Map<String, dynamic>;
    if (envelope['scheme'] != CryptoConstants.schemeRatchet1) {
      throw FormatException('Not a ratchet message');
    }
    final counter = envelope['counter'] as int;
    if (counter <= recvCounter) {
      throw StateError('Replay detected');
    }
    recvCounter = counter;
    final messageKey = await _recvKeyForCounter(counter);
    final aeadKey = await CryptoAead.secretKeyFromBytes(
      Uint8List.fromList(messageKey),
    );
    return CryptoAead.decryptAesGcm(
      ciphertextWithTag: base64Decode(envelope['ciphertext'] as String),
      key: aeadKey,
      nonce: base64Decode(envelope['nonce'] as String),
    );
  }

  Future<List<int>> _nextSendKey() async {
    final key = await CryptoKdf.hkdf(
      sharedSecret: sendingChainKey,
      info: utf8.encode('msg-$sendCounter'),
    );
    sendCounter++;
    return await key.extractBytes();
  }

  Future<List<int>> _recvKeyForCounter(int counter) async {
    final key = await CryptoKdf.hkdf(
      sharedSecret: receivingChainKey,
      info: utf8.encode('msg-$counter'),
    );
    return await key.extractBytes();
  }

  Map<String, dynamic> toJson() => {
        'rootKey': base64Encode(rootKey),
        'sendingChainKey': base64Encode(sendingChainKey),
        'receivingChainKey': base64Encode(receivingChainKey),
        'sendCounter': sendCounter,
        'recvCounter': recvCounter,
      };

  static RatchetSession fromJson(Map<String, dynamic> json) {
    return RatchetSession(
      rootKey: base64Decode(json['rootKey'] as String),
      sendingChainKey: base64Decode(json['sendingChainKey'] as String),
      receivingChainKey: base64Decode(json['receivingChainKey'] as String),
      sendCounter: json['sendCounter'] as int,
      recvCounter: json['recvCounter'] as int,
    );
  }
}
