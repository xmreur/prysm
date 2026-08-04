import 'dart:convert';
import 'dart:typed_data';

import 'package:prysm/crypto/aead.dart';
import 'package:prysm/crypto/constants.dart';
import 'package:prysm/crypto/envelope.dart';
import 'package:prysm/crypto/kdf.dart';

/// Simplified Double Ratchet session for 1:1 chats (Phase 2).
class RatchetSession {
  RatchetSession({
    required this.sharedMaterial,
    required this.isInitiator,
    required this.sendCounter,
    required this.recvCounter,
    Set<int>? skippedCounters,
  }) : skippedCounters = skippedCounters ?? <int>{};

  final Uint8List sharedMaterial;
  final bool isInitiator;
  int sendCounter;
  int recvCounter;
  final Set<int> skippedCounters;

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
    Uint8List plaintext, {
    Map<String, dynamic>? handshake,
  }) async {
    final counter = sendCounter;
    final scheme = CryptoConstants.schemeRatchet2;
    const alg = 'aes-gcm';
    final messageKey = await _messageKey(
      role: isInitiator ? 'send' : 'recv',
      counter: counter,
    );
    sendCounter++;
    final aeadKey = await CryptoAead.secretKeyFromBytes(
      Uint8List.fromList(messageKey),
    );
    final aad = CryptoEnvelope.ratchetAad(
      scheme: scheme,
      counter: counter,
      alg: alg,
      handshake: handshake,
    );
    final enc = await CryptoAead.encryptAesGcm(
      plaintext,
      key: aeadKey,
      associatedData: aad,
    );
    final wire = jsonEncode({
      'crypto': CryptoConstants.cryptoVersion,
      'scheme': scheme,
      'alg': alg,
      'nonce': base64Encode(enc.nonce),
      'ciphertext': base64Encode(enc.ciphertext),
      'counter': counter,
    });
    return (wire: wire, handshake: handshake ?? <String, dynamic>{});
  }

  Future<Uint8List> decryptMessage(String wire) async {
    final envelope = jsonDecode(wire) as Map<String, dynamic>;
    final scheme = envelope['scheme'] as String?;
    if (scheme != CryptoConstants.schemeRatchet1 &&
        scheme != CryptoConstants.schemeRatchet2) {
      throw FormatException('Not a ratchet message');
    }
    final counter = envelope['counter'] as int;
    final isLateSkipped = skippedCounters.contains(counter);
    if (counter <= recvCounter && !isLateSkipped) {
      throw StateError('Replay detected');
    }
    if (!isLateSkipped && counter > recvCounter + 1) {
      final gap = counter - (recvCounter + 1);
      if (gap > CryptoConstants.ratchetMaxSkip) {
        throw StateError('Counter too far ahead');
      }
    }
    final messageKey = await _messageKey(
      role: isInitiator ? 'recv' : 'send',
      counter: counter,
    );
    final aeadKey = await CryptoAead.secretKeyFromBytes(
      Uint8List.fromList(messageKey),
    );
    final associatedData = scheme == CryptoConstants.schemeRatchet2
        ? CryptoEnvelope.ratchetAad(
            scheme: scheme!,
            counter: counter,
            alg: envelope['alg'] as String? ?? 'aes-gcm',
            crypto: envelope['crypto'] as String? ??
                CryptoConstants.cryptoVersion,
            handshake: envelope['handshake'] as Map<String, dynamic>?,
          )
        : const <int>[];
    final plain = await CryptoAead.decryptAesGcm(
      ciphertextWithTag: base64Decode(envelope['ciphertext'] as String),
      key: aeadKey,
      nonce: base64Decode(envelope['nonce'] as String),
      associatedData: associatedData,
    );
    if (isLateSkipped) {
      skippedCounters.remove(counter);
    } else if (counter > recvCounter + 1) {
      for (var i = recvCounter + 1; i < counter; i++) {
        skippedCounters.add(i);
      }
      recvCounter = counter;
    } else {
      recvCounter = counter;
    }
    return plain;
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
        'skippedCounters': (skippedCounters.toList()..sort()),
      };

  static RatchetSession fromJson(Map<String, dynamic> json) {
    return RatchetSession(
      sharedMaterial: base64Decode(json['sharedMaterial'] as String),
      isInitiator: json['isInitiator'] as bool? ?? true,
      sendCounter: json['sendCounter'] as int,
      recvCounter: json['recvCounter'] as int,
      skippedCounters: Set<int>.from(
        (json['skippedCounters'] as List<dynamic>?) ?? const [],
      ),
    );
  }
}
