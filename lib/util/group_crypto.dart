import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:encrypt/encrypt.dart' as e;
import 'package:pointycastle/export.dart';
import 'package:prysm/util/file_encrypt.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/rsa_helper.dart';

class GroupCrypto {
  static const String controlEnvelopeVersion = 'v2';

  static Uint8List _randomBytes(int length) {
    final rnd = Random.secure();
    return Uint8List.fromList(List.generate(length, (_) => rnd.nextInt(256)));
  }

  /// Generate a new 32-byte AES group key.
  static Uint8List generateGroupKey() => _randomBytes(32);

  static Map<String, String> _aesGcmEncrypt(Uint8List key, Uint8List plain) {
    final gcm = GCMBlockCipher(AESEngine());
    final iv = _randomBytes(12);
    final aeadParams = AEADParameters(KeyParameter(key), 128, iv, Uint8List(0));
    gcm.init(true, aeadParams);
    final cipherText = gcm.process(plain);
    return {
      'iv': base64Encode(iv),
      'ct': base64Encode(cipherText),
    };
  }

  static Uint8List _aesGcmDecrypt(Uint8List key, Uint8List iv, Uint8List ciphertext) {
    final gcm = GCMBlockCipher(AESEngine());
    final aeadParams = AEADParameters(KeyParameter(key), 128, iv, Uint8List(0));
    gcm.init(false, aeadParams);
    return gcm.process(ciphertext);
  }

  /// Hybrid AES+RSA envelope for group control payloads (invite, rotate, etc.).
  static String encryptControlPayloadForPeer(
    String plaintextJson,
    KeyManager keyManager,
    RSAPublicKey peerPublicKey,
  ) {
    final sessionKey = generateGroupKey();
    final enc = _aesGcmEncrypt(sessionKey, utf8.encode(plaintextJson));
    final rsaKey = keyManager.encryptBytesForPeer(sessionKey, peerPublicKey);
    return jsonEncode({
      'envelope': controlEnvelopeVersion,
      'rsa_key': rsaKey,
      'iv': enc['iv'],
      'data': enc['ct'],
    });
  }

  /// Decrypt control payload; supports v2 envelope and legacy direct RSA.
  static String decryptControlPayload(String wire, KeyManager keyManager) {
    final trimmed = wire.trimLeft();
    if (trimmed.startsWith('{')) {
      final parsed = jsonDecode(wire);
      if (parsed is! Map<String, dynamic>) {
        throw ArgumentError('Invalid control payload JSON');
      }
      if (parsed['envelope'] == controlEnvelopeVersion) {
        try {
          final sessionKey = keyManager.decryptBytes(parsed['rsa_key'] as String);
          final iv = base64Decode(parsed['iv'] as String);
          final ct = base64Decode(parsed['data'] as String);
          final plain = _aesGcmDecrypt(sessionKey, iv, ct);
          return utf8.decode(plain);
        } catch (e) {
          throw ArgumentError('Failed to decrypt v2 control payload: $e');
        }
      }
      throw ArgumentError('Unknown control payload envelope');
    }
    return keyManager.decryptMessage(wire);
  }

  /// Encrypt plaintext with group AES key. Returns JSON string `{iv, ct}`.
  static String encryptText(Uint8List groupKey, String plaintext) {
    final enc = _aesGcmEncrypt(groupKey, utf8.encode(plaintext));
    return jsonEncode(enc);
  }

  /// Decrypt group message JSON `{iv, ct}` to plaintext.
  static String decryptText(Uint8List groupKey, String encryptedJson) {
    final map = jsonDecode(encryptedJson) as Map<String, dynamic>;
    final iv = base64Decode(map['iv'] as String);
    final ct = base64Decode(map['ct'] as String);
    final plain = _aesGcmDecrypt(groupKey, iv, ct);
    return utf8.decode(plain);
  }

  /// Encrypt file bytes for group chat using group AES key.
  static String encryptGroupFile(Uint8List groupKey, Uint8List bytes) {
    final fileAesKey = AESHelper.generateAESKey();
    final iv = AESHelper.generateIV();
    final encryptedBytes = AESHelper.encryptBytes(bytes, fileAesKey, iv);
    final wrappedKey = _aesGcmEncrypt(groupKey, fileAesKey.bytes);
    return jsonEncode({
      'group_wrapped_key': wrappedKey,
      'iv': iv.base64,
      'data': base64Encode(encryptedBytes),
    });
  }

  /// Decrypt group file payload to raw bytes.
  static Uint8List decryptGroupFile(Uint8List groupKey, String payloadJson) {
    final hybrid = jsonDecode(payloadJson) as Map<String, dynamic>;
    final wrapped = hybrid['group_wrapped_key'] as Map<String, dynamic>;
    final ivWrapped = base64Decode(wrapped['iv'] as String);
    final ctWrapped = base64Decode(wrapped['ct'] as String);
    final fileKeyBytes = _aesGcmDecrypt(groupKey, ivWrapped, ctWrapped);

    final iv = e.IV.fromBase64(hybrid['iv'] as String);
    final encryptedData = base64Decode(hybrid['data'] as String);
    final aesKey = e.Key(Uint8List.fromList(fileKeyBytes));
    return AESHelper.decryptBytes(encryptedData, aesKey, iv);
  }

  /// RSA-encrypt group key bytes for storage (self) or distribution (peer).
  static String encryptGroupKeyForStorage(
    Uint8List groupKey,
    KeyManager keyManager, {
    RSAPublicKey? peerPublicKey,
  }) {
    if (peerPublicKey != null) {
      return keyManager.encryptBytesForPeer(groupKey, peerPublicKey);
    }
    return keyManager.encryptBytesForSelf(groupKey);
  }

  /// RSA-decrypt stored group key bytes.
  static Uint8List decryptGroupKey(String encryptedKey, KeyManager keyManager) {
    return keyManager.decryptBytes(encryptedKey);
  }

  /// Encrypt group key for a specific member in invite/rotate payloads.
  static String encryptGroupKeyForMember(
    Uint8List groupKey,
    KeyManager keyManager,
    RSAPublicKey memberPublicKey,
  ) {
    return RSAHelper.encryptBytesWithPublicKey(groupKey, memberPublicKey);
  }

  /// Decrypt per-member encrypted group key from control payload.
  static Uint8List decryptGroupKeyFromPayload(
    String encryptedGroupKey,
    KeyManager keyManager,
  ) {
    return keyManager.decryptBytes(encryptedGroupKey);
  }
}
