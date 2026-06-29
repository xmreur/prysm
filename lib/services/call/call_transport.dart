import 'dart:async';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';
import 'package:prysm/services/ws_connection_manager.dart';
import 'package:prysm/transport/transport_provider.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/util/key_manager.dart';

abstract class CallTransport {
  Future<void> ensureConnected(String peerOnion);
  Future<void> send(String peerOnion, String op, Map<String, dynamic> payload);
  Future<void> sendBytes(String peerOnion, Uint8List bytes);
  void pinPeer(String peerOnion);
  void unpinPeer(String peerOnion);
  Stream<List<int>> binaryFramesFor(String peerOnion);
}

abstract class CallKeyResolver {
  Future<RSAPublicKey?> resolve(String peerOnion);
}

class WsCallTransport implements CallTransport {
  WsCallTransport(this._manager);

  final WsConnectionManager _manager;

  WsConnectionManager get manager => _manager;

  @override
  Future<void> ensureConnected(String peerOnion) =>
      _manager.ensureConnected(peerOnion);

  @override
  Future<void> send(
    String peerOnion,
    String op,
    Map<String, dynamic> payload,
  ) =>
      _manager.send(peerOnion, op, payload: payload);

  @override
  Future<void> sendBytes(String peerOnion, Uint8List bytes) =>
      _manager.sendBytes(peerOnion, bytes);

  @override
  void pinPeer(String peerOnion) => _manager.pinPeer(peerOnion);

  @override
  void unpinPeer(String peerOnion) => _manager.unpinPeer(peerOnion);

  @override
  Stream<List<int>> binaryFramesFor(String peerOnion) =>
      _manager.binaryFramesFor(peerOnion);
}

class DbCallKeyResolver implements CallKeyResolver {
  DbCallKeyResolver(this._keyManager);

  final KeyManager _keyManager;

  @override
  Future<RSAPublicKey?> resolve(String peerOnion) async {
    final user = await DBHelper.getUserById(peerOnion);
    final cached = user?['publicKeyPem'] as String?;
    if (cached != null && cached.isNotEmpty && cached != 'NONE') {
      try {
        return _keyManager.importPeerPublicKey(cached);
      } catch (_) {}
    }

    try {
      final pem = await TransportProvider.getPublicOrFallback(peerOnion);
      if (pem.isEmpty) return null;
      return _keyManager.importPeerPublicKey(pem);
    } catch (_) {
      return null;
    }
  }
}

CallTransport defaultCallTransport() {
  if (!TransportProvider.isConfigured) {
    throw StateError('TransportProvider.configure() must be called first');
  }
  return WsCallTransport(TransportProvider.instance.wsManager);
}
