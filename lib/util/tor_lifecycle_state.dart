/// Tor process lifecycle for gating outbound network traffic.
enum TorLifecycleState {
  stopped,
  restarting,
  bootstrapping,
  ready,
}

/// Shared Tor lifecycle state across gate, WS manager, and sync coordinator.
class TorLifecycleNotifier {
  TorLifecycleNotifier._();

  static final TorLifecycleNotifier instance = TorLifecycleNotifier._();

  TorLifecycleState _state = TorLifecycleState.stopped;

  TorLifecycleState get state => _state;

  bool get blocked => _state != TorLifecycleState.ready;

  void update(TorLifecycleState next) {
    _state = next;
  }
}
