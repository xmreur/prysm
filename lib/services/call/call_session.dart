import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:pointycastle/export.dart';
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

/// Per-call symmetric encryption for audio frames.
class CallSession {
  CallSession._({
    required this.callId,
    required this.sessionId,
    required this.peerOnion,
    required this.role,
    required Uint8List key,
    required Uint8List salt,
    required this.codec,
  })  : _key = key,
        _salt = salt;

  final String callId;
  final int sessionId;
  final String peerOnion;
  final CallRole role;
  final CallCodecParams codec;

  final Uint8List _key;
  final Uint8List _salt;
  int _sendSeq = 0;
  int _recvSeq = -1;

  static CallSession createOutbound({
    required String callId,
    required int sessionId,
    required String peerOnion,
    CallCodecParams codec = const CallCodecParams(),
  }) {
    final rnd = Random.secure();
    final key = Uint8List.fromList(
      List.generate(32, (_) => rnd.nextInt(256)),
    );
    final salt = Uint8List.fromList(
      List.generate(4, (_) => rnd.nextInt(256)),
    );
    return CallSession._(
      callId: callId,
      sessionId: sessionId,
      peerOnion: peerOnion,
      role: CallRole.caller,
      key: key,
      salt: salt,
      codec: codec,
    );
  }

  static CallSession fromInbound({
    required String callId,
    required int sessionId,
    required String peerOnion,
    required String wrappedKey,
    required KeyManager keyManager,
    CallCodecParams codec = const CallCodecParams(),
  }) {
    final material = keyManager.decryptBytes(wrappedKey);
    if (material.length < 36) {
      throw const FormatException('Invalid wrapped call key');
    }
    final key = Uint8List.fromList(material.sublist(0, 32));
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

  String wrapKeyForPeer(RSAPublicKey peerKey, KeyManager keyManager) {
    final material = Uint8List(36)
      ..setRange(0, 32, _key)
      ..setRange(32, 36, _salt);
    return keyManager.encryptBytesForPeer(material, peerKey);
  }

  Uint8List encryptAudioFrame(Uint8List opusPayload) {
    final seq = _sendSeq++;
    final cipher = _cipherForSeq(seq, encrypt: true);
    final encrypted = cipher.process(opusPayload);
    return CallAudioFrame(
      sessionId: sessionId,
      seq: seq,
      payload: encrypted,
    ).encode();
  }

  Uint8List? decryptAudioFrame(List<int> raw) {
    CallAudioFrame frame;
    try {
      frame = CallAudioFrame.decode(raw);
    } catch (_) {
      return null;
    }
    if (frame.sessionId != sessionId) return null;
    if (frame.seq <= _recvSeq) return null;
    _recvSeq = frame.seq;
    final cipher = _cipherForSeq(frame.seq, encrypt: false);
    try {
      return cipher.process(Uint8List.fromList(frame.payload));
    } catch (_) {
      return null;
    }
  }

  StreamCipher _cipherForSeq(int seq, {required bool encrypt}) {
    final engine = ChaCha20Engine();
    engine.init(
      encrypt,
      ParametersWithIV<KeyParameter>(
        KeyParameter(_key),
        _nonceForSeq(seq),
      ),
    );
    return engine;
  }

  Uint8List _nonceForSeq(int seq) {
    final nonce = Uint8List(8);
    nonce.setRange(0, 4, _salt);
    final view = ByteData.sublistView(nonce);
    view.setUint32(4, seq, Endian.big);
    return nonce;
  }

  @visibleForTesting
  Uint8List secretKeyBytes() => Uint8List.fromList(_key);
}

int asInt(dynamic value, [int defaultValue = 0]) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return defaultValue;
}
