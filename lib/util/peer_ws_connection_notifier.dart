import 'dart:async';

class PeerWsConnectionEvent {
  const PeerWsConnectionEvent({
    required this.peerOnion,
    required this.connected,
  });

  final String peerOnion;
  final bool connected;
}

/// Broadcasts peer WebSocket connect/disconnect events.
class PeerWsConnectionNotifier {
  PeerWsConnectionNotifier._();
  static final PeerWsConnectionNotifier instance = PeerWsConnectionNotifier._();

  final _controller = StreamController<PeerWsConnectionEvent>.broadcast();

  Stream<PeerWsConnectionEvent> get onChanged => _controller.stream;

  void notify(String peerOnion, {required bool connected}) {
    if (_controller.isClosed) return;
    _controller.add(
      PeerWsConnectionEvent(peerOnion: peerOnion, connected: connected),
    );
  }
}
