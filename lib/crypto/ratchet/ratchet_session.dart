import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:prysm/crypto/aead.dart';
import 'package:prysm/crypto/constants.dart';
import 'package:prysm/crypto/kdf.dart';

/// Simplified Double Ratchet session for 1:1 chats (Phase 2).
class RatchetSession {
  RatchetSession({
    required this.sharedMaterial,
    required this.isInitiator,
    required this.sendCounter,
    required this.recvCounter,
  });

  final Uint8List sharedMaterial;
  final bool isInitiator;
  int sendCounter;
  int recvCounter;

  static final Uint8List _ratchetSalt =
      Uint8List.fromList(utf8.encode('prysm/ratchet/root-salt'));

  static Future<RatchetSession> initializeAsInitiator(
    Uint8List sharedMaterial,
  ) async {
    return RatchetSession(
      sharedMaterial: sharedMaterial,
      isInitiator: true,
      sendCounter: 0,
      recvCounter: -1,
    );
  }

  static Future<RatchetSession> initializeAsResponder(
    Uint8List sharedMaterial,
  ) async {
    return RatchetSession(
      sharedMaterial: sharedMaterial,
      isInitiator: false,
      sendCounter: 0,
      recvCounter: -1,
    );
  }

  Future<({String wire, Map<String, dynamic> handshake})> encryptMessage(
    Uint8List plaintext,
  ) async {
    final counter = sendCounter;
    final messageKey = await _messageKey(
      role: isInitiator ? 'send' : 'recv',
      counter: counter,
    );
    sendCounter++;
    final aeadKey = await CryptoAead.secretKeyFromBytes(
      Uint8List.fromList(messageKey),
    );
    final enc = await CryptoAead.encryptAesGcm(plaintext, key: aeadKey);
    final wire = jsonEncode({
      'crypto': CryptoConstants.cryptoVersion,
      'scheme': CryptoConstants.schemeRatchet1,
      'nonce': base64Encode(enc.nonce),
      'ciphertext': base64Encode(enc.ciphertext),
      'counter': counter,
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
    final messageKey = await _messageKey(
      role: isInitiator ? 'recv' : 'send',
      counter: counter,
    );
    final aeadKey = await CryptoAead.secretKeyFromBytes(
      Uint8List.fromList(messageKey),
    );
    return CryptoAead.decryptAesGcm(
      ciphertextWithTag: base64Decode(envelope['ciphertext'] as String),
      key: aeadKey,
      nonce: base64Decode(envelope['nonce'] as String),
    );
  }

  Future<List<int>> _messageKey({
    required String role,
    required int counter,
  }) async {
    final key = await CryptoKdf.hkdf(
      sharedSecret: sharedMaterial,
      info: utf8.encode(
        '${CryptoConstants.hkdfInfoRatchet}/$role/msg/$counter',
      ),
      salt: _ratchetSalt,
    );
    return await key.extractBytes();
  }

  Map<String, dynamic> toJson() => {
        'sharedMaterial': base64Encode(sharedMaterial),
        'isInitiator': isInitiator,
        'sendCounter': sendCounter,
        'recvCounter': recvCounter,
      };

  static RatchetSession fromJson(Map<String, dynamic> json) {
    return RatchetSession(
      sharedMaterial: base64Decode(json['sharedMaterial'] as String),
      isInitiator: json['isInitiator'] as bool? ?? true,
      sendCounter: json['sendCounter'] as int,
      recvCounter: json['recvCounter'] as int,
    );
  }
}
