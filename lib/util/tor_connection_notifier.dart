import 'dart:async';

enum TorConnectionState { connected, connecting, disconnected }

/// Broadcasts runtime Tor health from [HomeScreen] to tray and other listeners.
class TorConnectionNotifier {
  TorConnectionNotifier._();
  static final TorConnectionNotifier instance = TorConnectionNotifier._();

  final _controller = StreamController<TorConnectionState>.broadcast();
  TorConnectionState _state = TorConnectionState.connected;

  Stream<TorConnectionState> get onStateChanged => _controller.stream;
  TorConnectionState get state => _state;

  void update(TorConnectionState state) {
    if (state == _state) return;
    _state = state;
    if (!_controller.isClosed) {
      _controller.add(_state);
    }
  }
}
