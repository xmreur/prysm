import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:prysm/crypto/aead.dart';
import 'package:prysm/crypto/identity.dart';
import 'package:prysm/crypto/kdf.dart';
import 'package:prysm/services/call/call_session.dart';
import 'package:prysm/transport/ws_protocol.dart';
import 'package:prysm/util/key_manager.dart';

/// Shared-key group-call crypto. Nonce is `salt || seq || senderSlot` so
/// two participants encrypting seq 0 cannot collide under ChaCha20-Poly1305.
class GroupCallSession {
  GroupCallSession._({
    required this.callId,
    required this.sessionId,
    required this.groupId,
    required this.members,
    required this.localOnion,
    required this.localSlot,
    required SecretKey key,
    required Uint8List salt,
    required this.codec,
  })  : _key = key,
        _salt = salt;

  final String callId;
  final int sessionId;
  final String groupId;
  final List<String> members;
  final String localOnion;
  final int localSlot;
  final CallCodecParams codec;

  final SecretKey _key;
  final Uint8List _salt;
  int _sendSeq = 0;
  final Map<int, int> _recvSeqBySlot = {};

  static GroupCallSession createOutbound({
    required String callId,
    required int sessionId,
    required String groupId,
    required List<String> members,
    required String localOnion,
    CallCodecParams codec = const CallCodecParams(),
  }) {
    final localSlot = members.indexOf(localOnion);
    if (localSlot < 0) {
      throw ArgumentError('local onion is not in the member list');
    }
    final keyBytes = CryptoKdf.randomBytes(32);
    final salt = CryptoKdf.randomBytes(4);
    return GroupCallSession._(
      callId: callId,
      sessionId: sessionId,
      groupId: groupId,
      members: List<String>.unmodifiable(members),
      localOnion: localOnion,
      localSlot: localSlot,
      key: SecretKey(keyBytes),
      salt: salt,
      codec: codec,
    );
  }

  static Future<GroupCallSession> fromInbound({
    required String callId,
    required int sessionId,
    required String groupId,
    required List<String> members,
    required String localOnion,
    required String wrappedKey,
    required KeyManager keyManager,
    required IdentityPublicKeys peer,
    CallCodecParams codec = const CallCodecParams(),
  }) async {
    final localSlot = members.indexOf(localOnion);
    if (localSlot < 0) {
      throw ArgumentError('local onion is not in the member list');
    }
    final material = await keyManager.decryptBytesFromPeer(
      wire: wrappedKey,
      peer: peer,
    );
    if (material.length < 36) {
      throw const FormatException('Invalid wrapped group call key');
    }
    return GroupCallSession._(
      callId: callId,
      sessionId: sessionId,
      groupId: groupId,
      members: List<String>.unmodifiable(members),
      localOnion: localOnion,
      localSlot: localSlot,
      key: SecretKey(material.sublist(0, 32)),
      salt: Uint8List.fromList(material.sublist(32, 36)),
      codec: codec,
    );
  }

  int? slotOf(String onion) {
    final slot = members.indexOf(onion);
    return slot < 0 ? null : slot;
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
    final aad = utf8.encode('$seq:$localSlot');
    final enc = await CryptoAead.encryptChaCha(
      opusPayload,
      key: _key,
      nonce: nonceFor(seq, localSlot),
      associatedData: aad,
    );
    return CallAudioFrame(
      sessionId: sessionId,
      seq: seq,
      payload: enc.ciphertext,
    ).encode();
  }

  Future<Uint8List?> decryptAudioFrame(
    List<int> raw, {
    required int senderSlot,
  }) async {
    if (senderSlot < 0 || senderSlot >= members.length) return null;
    CallAudioFrame frame;
    try {
      frame = CallAudioFrame.decode(raw);
    } catch (_) {
      return null;
    }
    if (frame.sessionId != sessionId) return null;
    final last = _recvSeqBySlot[senderSlot] ?? -1;
    if (frame.seq <= last) return null;
    final aad = utf8.encode('${frame.seq}:$senderSlot');
    try {
      final plain = await CryptoAead.decryptChaCha(
        ciphertextWithTag: Uint8List.fromList(frame.payload),
        key: _key,
        nonce: nonceFor(frame.seq, senderSlot),
        associatedData: aad,
      );
      _recvSeqBySlot[senderSlot] = frame.seq;
      return plain;
    } catch (_) {
      return null;
    }
  }

  @visibleForTesting
  Uint8List nonceFor(int seq, int slot) {
    final nonce = Uint8List(12);
    nonce.setRange(0, 4, _salt);
    final view = ByteData.sublistView(nonce);
    view.setUint32(4, seq, Endian.big);
    view.setUint32(8, slot, Endian.big);
    return nonce;
  }

  @visibleForTesting
  Future<Uint8List> secretKeyBytes() async {
    final bytes = await _key.extractBytes();
    return Uint8List.fromList(bytes);
  }
}
