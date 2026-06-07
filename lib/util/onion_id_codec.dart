import 'dart:convert';
import 'dart:typed_data';

import 'package:bs58/bs58.dart';

String encodeOnionToBase58(String onion) {
  final cleanOnion = onion.endsWith('.onion')
      ? onion.substring(0, onion.length - 6)
      : onion;
  return base58.encode(Uint8List.fromList(utf8.encode(cleanOnion)));
}

String decodeBase58ToOnion(String base58String) {
  final bytes = base58.decode(base58String);
  final onion = utf8.decode(bytes);
  return '$onion.onion';
}
