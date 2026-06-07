import 'dart:convert';
import 'dart:typed_data';

import 'package:encrypt/encrypt.dart' as e;
import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/asymmetric/api.dart';
import 'package:prysm/util/file_encrypt.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/message_modify_payload.dart';
import 'package:prysm/util/rsa_helper.dart';

void main() {
  test('edit payload JSON exceeds RSA PKCS#1 plaintext limit', () {
    final payload = MessageModifyPayload(
      targetMessageId: '550e8400-e29b-41d4-a716-446655440000',
      action: 'edit',
      encryptedBody: 'x' * 684,
      modifiedAt: 1_700_000_000_000,
    );

    expect(utf8.encode(payload.encode()).length, greaterThan(501));
  });

  test('hybrid envelope round-trips direct modify payload', () {
    final pair = RSAHelper.generateKeyPair();
    final publicKey = pair.publicKey as RSAPublicKey;
    final privateKey = pair.privateKey as RSAPrivateKey;

    final payload = MessageModifyPayload(
      targetMessageId: '550e8400-e29b-41d4-a716-446655440000',
      action: 'edit',
      encryptedBody: 'encrypted-body-placeholder',
      modifiedAt: 1_700_000_000_000,
    );
    final plaintext = payload.encode();

    final aesKey = AESHelper.generateAESKey();
    final iv = AESHelper.generateIV();
    final encryptedBytes = AESHelper.encryptBytes(
      Uint8List.fromList(utf8.encode(plaintext)),
      aesKey,
      iv,
    );
    final envelope = jsonEncode({
      'aes_key': RSAHelper.encryptBytesWithPublicKey(aesKey.bytes, publicKey),
      'iv': iv.base64,
      'data': base64Encode(encryptedBytes),
    });

    expect(KeyManager.isHybridEnvelope(envelope), isTrue);

    final hybrid = jsonDecode(envelope) as Map<String, dynamic>;
    final aesKeyBytes = RSAHelper.decryptBytesWithPrivateKey(
      base64Decode(hybrid['aes_key'] as String),
      privateKey,
    );
    final decrypted = AESHelper.decryptBytes(
      base64Decode(hybrid['data'] as String),
      e.Key(Uint8List.fromList(aesKeyBytes)),
      e.IV.fromBase64(hybrid['iv'] as String),
    );
    final decoded = utf8.decode(decrypted);

    expect(decoded, plaintext);
    expect(MessageModifyPayload.decode(decoded).targetMessageId,
        payload.targetMessageId);
  });
}
