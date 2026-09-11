// Valid Tor v3 hidden-service triplets for tests: real file headers and a
// hostname actually derived from the public key, so fixtures survive
// HsTransferKeys.isValidTriplet().
import 'dart:convert';

import 'package:prysm/util/hs_transfer_keys.dart';

/// Tor key-file headers, zero-padded to 32 bytes.
List<int> _header(String text) {
  final bytes = utf8.encode(text);
  return [...bytes, ...List.filled(32 - bytes.length, 0)];
}

/// A deterministic, format-valid triplet. [seed] varies the public key, so
/// two calls with different seeds yield different onions.
Map<String, String> validHsTriplet({int seed = 1}) {
  final pubKey = List<int>.generate(32, (i) => (i * 7 + seed) & 0xff);
  final secret = [
    ..._header('== ed25519v1-secret: type0 =='),
    ...List<int>.generate(64, (i) => (i * 3 + seed) & 0xff),
  ];
  final public = [..._header('== ed25519v1-public: type0 =='), ...pubKey];
  final hostname = HsTransferKeys.onionFromPublicKey(pubKey);
  return {
    HsTransferKeys.hostnameFile: base64Encode(utf8.encode('$hostname\n')),
    HsTransferKeys.secretKeyFile: base64Encode(secret),
    HsTransferKeys.publicKeyFile: base64Encode(public),
  };
}
