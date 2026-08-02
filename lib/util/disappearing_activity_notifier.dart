import 'dart:async';

/// Fired when a message with an expiry is inserted or a purge completes.
///
/// [SyncCoordinator] listens so it can re-arm its expiry timer.
class DisappearingActivityNotifier {
  DisappearingActivityNotifier._();
  static final DisappearingActivityNotifier instance =
      DisappearingActivityNotifier._();

  final _controller = StreamController<void>.broadcast();

  Stream<void> get onChanged => _controller.stream;

  void notify() {
    if (!_controller.isClosed) {
      _controller.add(null);
    }
  }
}
