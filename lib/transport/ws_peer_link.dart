import 'dart:async';

/// Full-duplex WebSocket transport to a single peer (outbound or inbound).
abstract class WsPeerLink {
  String get peerOnion;

  bool get isConnected;

  /// Unsolicited frames from the peer (messages, typing, etc.).
  Stream<Map<String, dynamic>> get onPushFrames;

  /// Binary frames (encrypted call audio) from the peer.
  Stream<List<int>> get onBinaryFrames;

  Future<void> send(String op, {Map<String, dynamic>? payload});

  Future<void> sendBytes(List<int> bytes);

  Future<Map<String, dynamic>> request(
    String op, {
    Map<String, dynamic>? payload,
    Duration timeout = const Duration(seconds: 30),
  });

  Future<void> sendPing();

  Future<void> close();
}
