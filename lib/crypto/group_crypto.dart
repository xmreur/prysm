import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:prysm/crypto/aead.dart';
import 'package:prysm/crypto/constants.dart';
import 'package:prysm/crypto/envelope.dart';
import 'package:prysm/crypto/identity.dart';
import 'package:prysm/crypto/kdf.dart';
import 'package:prysm/crypto/wire.dart';

/// Group chat cryptography (AES-GCM with shared group keys).
class GroupCryptoV2 {
  GroupCryptoV2._();

  static Uint8List generateGroupKey() =>
      CryptoKdf.randomBytes(CryptoConstants.aeadKeyLength);

  static Future<String> encryptText(Uint8List groupKey, String plaintext) async {
    final aeadKey = await CryptoAead.secretKeyFromBytes(groupKey);
    final enc = await CryptoAead.encryptAesGcm(utf8.encode(plaintext), key: aeadKey);
    return CryptoEnvelope.encode(CryptoEnvelope.groupAead1(
      iv: enc.nonce,
      ciphertext: enc.ciphertext,
    ));
  }

  static Future<String> decryptText(Uint8List groupKey, String wire) async {
    final envelope = CryptoEnvelope.tryParse(wire);
    if (envelope == null ||
        envelope['scheme'] != CryptoConstants.schemeGroupAead1) {
      throw ArgumentError('Invalid group message envelope');
    }
    final iv = base64Decode(envelope['iv'] as String);
    final ct = base64Decode(envelope['ct'] as String);
    final aeadKey = await CryptoAead.secretKeyFromBytes(groupKey);
    final plain = await CryptoAead.decryptAesGcm(
      ciphertextWithTag: ct,
      key: aeadKey,
      nonce: iv,
    );
    return utf8.decode(plain);
  }

  static Future<String> encryptControlPayload(
    String plaintextJson,
    IdentityKeyPair sender,
    SimplePublicKey peerAgreePublic,
  ) async {
    final sessionKey = generateGroupKey();
    final aeadKey = await CryptoAead.secretKeyFromBytes(sessionKey);
    final enc = await CryptoAead.encryptAesGcm(
      utf8.encode(plaintextJson),
      key: aeadKey,
    );
    final wrapped = await CryptoWire.wrapKeyForPeer(
      sessionKey,
      sender,
      peerAgreePublic,
    );
    return CryptoEnvelope.encode(CryptoEnvelope.controlWrap1(
      wrappedKey: wrapped,
      iv: enc.nonce,
      ciphertext: enc.ciphertext,
    ));
  }

  static Future<String> decryptControlPayload(
    String wire,
    IdentityKeyPair recipient,
  ) async {
    final envelope = CryptoEnvelope.tryParse(wire);
    if (envelope == null ||
        envelope['scheme'] != CryptoConstants.schemeControlWrap1) {
      throw ArgumentError('Invalid control envelope');
    }
    final wrapped = envelope['wrappedKey'] as Map<String, dynamic>;
    final iv = base64Decode(envelope['iv'] as String);
    final ct = base64Decode(envelope['ct'] as String);
    final sessionKey = await CryptoWire.unwrapKeyFromPeer(wrapped, recipient);
    final aeadKey = await CryptoAead.secretKeyFromBytes(sessionKey);
    final plain = await CryptoAead.decryptAesGcm(
      ciphertextWithTag: ct,
      key: aeadKey,
      nonce: iv,
    );
    return utf8.decode(plain);
  }

  static Future<String> encryptGroupFile(
    Uint8List groupKey,
    Uint8List bytes,
  ) async {
    final fileKey = generateGroupKey();
    final fileAeadKey = await CryptoAead.secretKeyFromBytes(fileKey);
    final enc = await CryptoAead.encryptAesGcm(bytes, key: fileAeadKey);
    final groupAeadKey = await CryptoAead.secretKeyFromBytes(groupKey);
    final wrappedEnc = await CryptoAead.encryptAesGcm(fileKey, key: groupAeadKey);
    final wrapped = {
      'iv': base64Encode(wrappedEnc.nonce),
      'ct': base64Encode(wrappedEnc.ciphertext),
    };
    return CryptoEnvelope.encode(CryptoEnvelope.fileAead1(
      wrappedKey: wrapped,
      nonce: enc.nonce,
      ciphertext: enc.ciphertext,
    ));
  }

  static Future<Uint8List> decryptGroupFile(
    Uint8List groupKey,
    String wire,
  ) async {
    final envelope = CryptoEnvelope.tryParse(wire);
    if (envelope == null ||
        envelope['scheme'] != CryptoConstants.schemeFileAead1) {
      throw ArgumentError('Invalid group file envelope');
    }
    final wrapped = envelope['wrappedKey'] as Map<String, dynamic>;
    final ivWrapped = base64Decode(wrapped['iv'] as String);
    final ctWrapped = base64Decode(wrapped['ct'] as String);
    final groupAeadKey = await CryptoAead.secretKeyFromBytes(groupKey);
    final fileKey = await CryptoAead.decryptAesGcm(
      ciphertextWithTag: ctWrapped,
      key: groupAeadKey,
      nonce: ivWrapped,
    );
    final nonce = base64Decode(envelope['nonce'] as String);
    final ciphertext = base64Decode(envelope['ciphertext'] as String);
    final fileAeadKey = await CryptoAead.secretKeyFromBytes(fileKey);
    return CryptoAead.decryptAesGcm(
      ciphertextWithTag: ciphertext,
      key: fileAeadKey,
      nonce: nonce,
    );
  }

  static Future<String> encryptGroupKeyForStorage(
    Uint8List groupKey,
    IdentityKeyPair identity, {
    SimplePublicKey? peerAgreePublic,
  }) async {
    final pub = peerAgreePublic ?? await identity.agreePublicKey;
    final wrapped = await CryptoWire.wrapKeyForPeer(groupKey, identity, pub);
    return CryptoEnvelope.encode({
      'crypto': CryptoConstants.cryptoVersion,
      'wrappedKey': wrapped,
    });
  }

  static Future<Uint8List> decryptGroupKey(
    String wire,
    IdentityKeyPair identity,
  ) async {
    final parsed = jsonDecode(wire) as Map<String, dynamic>;
    if (parsed['crypto'] != CryptoConstants.cryptoVersion) {
      throw ArgumentError('Invalid group key envelope');
    }
    final wrapped = parsed['wrappedKey'] as Map<String, dynamic>;
    return CryptoWire.unwrapKeyFromPeer(wrapped, identity);
  }

  /// Sender-key message encryption (epoch key + sender id + index).
  static Future<String> encryptWithSenderKey({
    required Uint8List epochKey,
    required String senderId,
    required int messageIndex,
    required String plaintext,
  }) async {
    final msgKey = await CryptoKdf.hkdf(
      sharedSecret: epochKey,
      info: utf8.encode(
        'prysm/group-sender/$senderId/$messageIndex',
      ),
    );
    final aeadKey = await CryptoAead.secretKeyFromBytes(
      Uint8List.fromList(await msgKey.extractBytes()),
    );
    final enc = await CryptoAead.encryptAesGcm(
      utf8.encode(plaintext),
      key: aeadKey,
    );
    return CryptoEnvelope.encode({
      'crypto': CryptoConstants.cryptoVersion,
      'scheme': CryptoConstants.schemeGroupSender1,
      'senderId': senderId,
      'index': messageIndex,
      'iv': base64Encode(enc.nonce),
      'ct': base64Encode(enc.ciphertext),
    });
  }

  static Future<String> decryptWithSenderKey({
    required Uint8List epochKey,
    required String wire,
  }) async {
    final envelope = CryptoEnvelope.tryParse(wire);
    if (envelope == null ||
        envelope['scheme'] != CryptoConstants.schemeGroupSender1) {
      throw ArgumentError('Invalid group sender envelope');
    }
    final senderId = envelope['senderId'] as String;
    final index = envelope['index'] as int;
    final msgKey = await CryptoKdf.hkdf(
      sharedSecret: epochKey,
      info: utf8.encode('prysm/group-sender/$senderId/$index'),
    );
    final aeadKey = await CryptoAead.secretKeyFromBytes(
      Uint8List.fromList(await msgKey.extractBytes()),
    );
    final iv = base64Decode(envelope['iv'] as String);
    final ct = base64Decode(envelope['ct'] as String);
    final plain = await CryptoAead.decryptAesGcm(
      ciphertextWithTag: ct,
      key: aeadKey,
      nonce: iv,
    );
    return utf8.decode(plain);
  }
}
