import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:prysm/crypto/identity.dart';
import 'package:prysm/crypto/wire.dart';

/// Encrypts a file payload off the UI isolate.
Future<Map<String, String>> encryptFileInBackground({
  required Uint8List bytes,
  required Map<String, dynamic> identityPrivateJson,
  required Uint8List peerAgreePublicBytes,
}) {
  return Isolate.run(
    () => _encryptFileIsolate(
      bytes: bytes,
      identityPrivateJson: identityPrivateJson,
      peerAgreePublicBytes: peerAgreePublicBytes,
    ),
  );
}

Future<Map<String, String>> _encryptFileIsolate({
  required Uint8List bytes,
  required Map<String, dynamic> identityPrivateJson,
  required Uint8List peerAgreePublicBytes,
}) async {
  final identity = await IdentityKeyPair.fromPrivateJson(identityPrivateJson);
  final peerAgreePublic = SimplePublicKey(
    peerAgreePublicBytes,
    type: KeyPairType.x25519,
  );
  final result = await CryptoWire.encryptFile(
    bytes,
    identity,
    peerAgreePublic,
  );
  return {
    'peerPayload': result.peerPayload,
    'selfPayload': result.selfPayload,
  };
}

Future<Map<String, dynamic>> identityPrivateJsonForIsolate(
  IdentityKeyPair identity,
) =>
    identity.toPrivateJson();

Future<Uint8List> peerAgreePublicBytes(SimplePublicKey peerAgreePublic) async =>
    Uint8List.fromList(peerAgreePublic.bytes);

/// Decode peer agree public from stored identity JSON.
Uint8List peerAgreePublicBytesFromIdentityJson(String identityJson) {
  final parsed = jsonDecode(identityJson) as Map<String, dynamic>;
  return base64Decode(parsed['agreePublic'] as String);
}
