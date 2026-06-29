import 'package:prysm/client/tor_websocket_client.dart';
import 'package:prysm/transport/ws_peer_link.dart';

/// Outbound dialer link wrapping [TorWebSocketClient].
class OutboundWsPeerLink implements WsPeerLink {
  OutboundWsPeerLink(this._client);

  final TorWebSocketClient _client;

  @override
  String get peerOnion => _client.peerOnion;

  @override
  bool get isConnected => _client.isConnected;

  @override
  Stream<Map<String, dynamic>> get onPushFrames => _client.onIncoming;

  @override
  Stream<List<int>> get onBinaryFrames => _client.onBinary;

  TorWebSocketClient get client => _client;

  @override
  Future<void> send(String op, {Map<String, dynamic>? payload}) =>
      _client.send(op, payload: payload);

  @override
  Future<void> sendBytes(List<int> bytes) => _client.sendBytes(bytes);

  @override
  Future<Map<String, dynamic>> request(
    String op, {
    Map<String, dynamic>? payload,
    Duration timeout = const Duration(seconds: 30),
  }) =>
      _client.request(op, payload: payload, timeout: timeout);

  @override
  Future<void> sendPing() => _client.sendPing();

  @override
  Future<void> close() => _client.dispose();
}
