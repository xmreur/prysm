import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:prysm/crypto/constants.dart';
import 'package:prysm/crypto/envelope.dart';
import 'package:prysm/crypto/group_crypto.dart' as gc;
import 'package:prysm/crypto/identity.dart';
import 'package:prysm/util/key_manager.dart';

/// Facade over [GroupCryptoV2] with legacy method names.
class GroupCrypto {
  GroupCrypto._();

  static const String controlEnvelopeVersion = CryptoConstants.cryptoVersion;

  static Uint8List generateGroupKey() => gc.GroupCryptoV2.generateGroupKey();

  static Future<String> encryptText(Uint8List groupKey, String plaintext) =>
      gc.GroupCryptoV2.encryptText(groupKey, plaintext);

  static Future<String> decryptText(Uint8List groupKey, String wire) =>
      gc.GroupCryptoV2.decryptText(groupKey, wire);

  static Future<String> encryptControlPayloadForPeer(
    String plaintextJson,
    KeyManager keyManager,
    IdentityPublicKeys peer,
  ) =>
      gc.GroupCryptoV2.encryptControlPayload(
        plaintextJson,
        keyManager.identity,
        peer.agreePublic,
      );

  static Future<String> decryptControlPayload(
    String wire,
    KeyManager keyManager,
  ) =>
      gc.GroupCryptoV2.decryptControlPayload(wire, keyManager.identity);

  static Future<String> encryptGroupFile(Uint8List groupKey, Uint8List bytes) =>
      gc.GroupCryptoV2.encryptGroupFile(groupKey, bytes);

  static Future<Uint8List> decryptGroupFile(Uint8List groupKey, String wire) =>
      gc.GroupCryptoV2.decryptGroupFile(groupKey, wire);

  static Future<String> encryptGroupKeyForStorage(
    Uint8List groupKey,
    KeyManager keyManager, {
    IdentityPublicKeys? peer,
  }) =>
      gc.GroupCryptoV2.encryptGroupKeyForStorage(
        groupKey,
        keyManager.identity,
        peerAgreePublic: peer?.agreePublic,
      );

  static Future<Uint8List> decryptGroupKey(
    String wire,
    KeyManager keyManager,
  ) =>
      gc.GroupCryptoV2.decryptGroupKey(wire, keyManager.identity);

  static Future<String> encryptGroupKeyForMember(
    Uint8List groupKey,
    KeyManager keyManager,
    IdentityPublicKeys member,
  ) =>
      gc.GroupCryptoV2.encryptGroupKeyForStorage(
        groupKey,
        keyManager.identity,
        peerAgreePublic: member.agreePublic,
      );

  static Future<Uint8List> decryptGroupKeyFromPayload(
    String wire,
    KeyManager keyManager,
  ) =>
      decryptGroupKey(wire, keyManager);

  static Future<String> encryptWithSenderKey({
    required Uint8List epochKey,
    required String senderId,
    required int messageIndex,
    required String plaintext,
  }) =>
      gc.GroupCryptoV2.encryptWithSenderKey(
        epochKey: epochKey,
        senderId: senderId,
        messageIndex: messageIndex,
        plaintext: plaintext,
      );

  static Future<String> decryptWithSenderKey({
    required Uint8List epochKey,
    required String wire,
  }) =>
      gc.GroupCryptoV2.decryptWithSenderKey(epochKey: epochKey, wire: wire);

  static bool isSenderKeyEnvelope(String wire) {
    final envelope = CryptoEnvelope.tryParse(wire);
    return envelope != null &&
        CryptoEnvelope.schemeOf(envelope) == CryptoConstants.schemeGroupSender1;
  }
}

typedef GroupCryptoV2 = GroupCrypto;
