/// How [TransportProvider.withPeer] selects HTTP vs WebSocket.
enum TransportPreference {
  /// Try WS connect (bounded budget) then fall back to HTTP.
  wsPreferred,

  /// Use WS only when already connected; otherwise HTTP immediately.
  wsIfConnected,

  /// Always HTTP — for wake hints and other lightweight nudges.
  httpOnly,
}
