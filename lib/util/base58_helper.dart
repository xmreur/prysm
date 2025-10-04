import 'dart:typed_data';
import 'package:bs58/bs58.dart';

String encodeBase58(String hexString) {
  final bytes = hexToBytes(hexString);
  return base58.encode(Uint8List.fromList(bytes));
}

String decodeBase58(String b58String) {
  final bytes = base58.decode(b58String);
  return bytesToHex(bytes);
}

List<int> hexToBytes(String hex) {
  final result = <int>[];
  for (int i = 0; i < hex.length; i += 2) {
    result.add(int.parse(hex.substring(i, i + 2), radix: 16));
  }
  return result;
}

String bytesToHex(List<int> bytes) {
  final buffer = StringBuffer();
  for (final b in bytes) {
    buffer.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}
