import 'dart:async';

/// Narrow transport interface used by [SideChannelTransport].
///
/// Implementations decide how the payload is delivered (HTTP POST, WebSocket,
/// or a test fake). [SideChannelTransport] owns the retry policy.
abstract class SideChannelPostman {
  Future<void> postDirect({
    required String peerId,
    required Map<String, dynamic> payload,
  });

  Future<void> postGroup({
    required String targetMemberId,
    required Map<String, dynamic> payload,
  });
}
