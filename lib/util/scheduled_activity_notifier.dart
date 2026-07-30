import 'dart:async';

/// Fired when the scheduled-message queue changes (schedule or cancel).
///
/// [SyncCoordinator] listens so it can re-arm its send timer for the new
/// earliest due time instead of waiting out the previous one.
class ScheduledActivityNotifier {
  ScheduledActivityNotifier._();
  static final ScheduledActivityNotifier instance =
      ScheduledActivityNotifier._();

  final _controller = StreamController<void>.broadcast();

  Stream<void> get onChanged => _controller.stream;

  void notify() {
    if (!_controller.isClosed) {
      _controller.add(null);
    }
  }
}
