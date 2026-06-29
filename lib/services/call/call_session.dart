import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:prysm/crypto/aead.dart';
import 'package:prysm/crypto/constants.dart';
import 'package:prysm/crypto/identity.dart';
import 'package:prysm/crypto/kdf.dart';
import 'package:prysm/crypto/wire.dart';
import 'package:prysm/transport/ws_protocol.dart';
import 'package:prysm/util/key_manager.dart';

enum CallRole { caller, callee }

class CallCodecParams {
  const CallCodecParams({
    this.sampleRate = 16000,
    this.channels = 1,
    this.frameDurationMs = 20,
  });

  final int sampleRate;
  final int channels;
  final int frameDurationMs;
}

/// Per-call symmetric encryption for audio frames (ChaCha20-Poly1305).
class CallSession {
  CallSession._({
    required this.callId,
    required this.sessionId,
    required this.peerOnion,
    required this.role,
    required SecretKey key,
    required Uint8List salt,
    required this.codec,
  })  : _key = key,
        _salt = salt;

  final String callId;
  final int sessionId;
  final String peerOnion;
  final CallRole role;
  final CallCodecParams codec;

  final SecretKey _key;
  final Uint8List _salt;
  int _sendSeq = 0;
  int _recvSeq = -1;

  static CallSession createOutbound({
    required String callId,
    required int sessionId,
    required String peerOnion,
    CallCodecParams codec = const CallCodecParams(),
  }) {
    final keyBytes = CryptoKdf.randomBytes(32);
    final salt = CryptoKdf.randomBytes(4);
    return CallSession._(
      callId: callId,
      sessionId: sessionId,
      peerOnion: peerOnion,
      role: CallRole.caller,
      key: SecretKey(keyBytes),
      salt: salt,
      codec: codec,
    );
  }

  static Future<CallSession> fromInbound({
    required String callId,
    required int sessionId,
    required String peerOnion,
    required String wrappedKey,
    required KeyManager keyManager,
    CallCodecParams codec = const CallCodecParams(),
  }) async {
    final material = await keyManager.decryptBytes(wrappedKey);
    if (material.length < 36) {
      throw const FormatException('Invalid wrapped call key');
    }
    final key = SecretKey(material.sublist(0, 32));
    final salt = Uint8List.fromList(material.sublist(32, 36));
    return CallSession._(
      callId: callId,
      sessionId: sessionId,
      peerOnion: peerOnion,
      role: CallRole.callee,
      key: key,
      salt: salt,
      codec: codec,
    );
  }

  Future<String> wrapKeyForPeer(
    IdentityPublicKeys peer,
    KeyManager keyManager,
  ) async {
    final keyBytes = await _key.extractBytes();
    final material = Uint8List(36)
      ..setRange(0, 32, keyBytes)
      ..setRange(32, 36, _salt);
    return keyManager.encryptBytesForPeer(material, peer);
  }

  Future<Uint8List> encryptAudioFrame(Uint8List opusPayload) async {
    final seq = _sendSeq++;
    final aad = utf8.encode('$seq');
    final enc = await CryptoAead.encryptChaCha(
      opusPayload,
      key: _key,
      nonce: _nonceForSeq(seq),
      associatedData: aad,
    );
    final encrypted = CallAudioFrame(
      sessionId: sessionId,
      seq: seq,
      payload: enc.ciphertext,
    ).encode();
    return encrypted;
  }

  Future<Uint8List?> decryptAudioFrame(List<int> raw) async {
    CallAudioFrame frame;
    try {
      frame = CallAudioFrame.decode(raw);
    } catch (_) {
      return null;
    }
    if (frame.sessionId != sessionId) return null;
    if (frame.seq <= _recvSeq) return null;
    _recvSeq = frame.seq;
    final aad = utf8.encode('${frame.seq}');
    try {
      return await CryptoAead.decryptChaCha(
        ciphertextWithTag: Uint8List.fromList(frame.payload),
        key: _key,
        nonce: _nonceForSeq(frame.seq),
        associatedData: aad,
      );
    } catch (_) {
      return null;
    }
  }

  Uint8List _nonceForSeq(int seq) {
    final nonce = Uint8List(12);
    nonce.setRange(0, 4, _salt);
    final view = ByteData.sublistView(nonce);
    view.setUint32(4, seq, Endian.big);
    return nonce;
  }

  @visibleForTesting
  Future<Uint8List> secretKeyBytes() async {
    final bytes = await _key.extractBytes();
    return Uint8List.fromList(bytes);
  }
}

int asInt(dynamic value, [int defaultValue = 0]) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return defaultValue;
}
