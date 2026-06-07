import 'dart:convert';

import 'package:encrypt/encrypt.dart' as e;
import 'package:flutter/foundation.dart';
import 'package:prysm/util/file_encrypt.dart';
import 'package:prysm/util/key_manager.dart';

/// Decrypt / resolve raw bytes from an encrypted or plain payload.
Future<Uint8List> resolveFileBytes({
  required String source,
  required KeyManager keyManager,
}) async {
  if (source.isEmpty) return Uint8List(0);

  if (source.trimLeft().startsWith('{')) {
    final hybrid = jsonDecode(source) as Map<String, dynamic>;
    final aesKeyBytes = keyManager.decryptMyMessageBytes(hybrid['aes_key'] as String);
    return compute(_aesDecryptFilePayload, {
      'aesKey': aesKeyBytes,
      'iv': hybrid['iv'],
      'data': hybrid['data'],
    });
  }

  return base64Decode(source);
}

Uint8List _aesDecryptFilePayload(Map<String, dynamic> args) {
  final aesKey = e.Key(Uint8List.fromList(List<int>.from(args['aesKey'] as List)));
  final iv = e.IV.fromBase64(args['iv'] as String);
  final encryptedData = base64Decode(args['data'] as String);
  return AESHelper.decryptBytes(encryptedData, aesKey, iv);
}
