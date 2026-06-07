import 'dart:async';

/// Fired when the outbound pending queue changes (insert, remove, or flush).
class PendingActivityNotifier {
  PendingActivityNotifier._();
  static final PendingActivityNotifier instance = PendingActivityNotifier._();

  final _controller = StreamController<void>.broadcast();

  Stream<void> get onChanged => _controller.stream;

  void notify() {
    if (!_controller.isClosed) {
      _controller.add(null);
    }
  }
}
