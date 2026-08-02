import 'dart:async';

/// Notifies open chats when a conversation's disappearing timer changes.
class DisappearingTimerRefreshNotifier {
  DisappearingTimerRefreshNotifier._();
  static final DisappearingTimerRefreshNotifier instance =
      DisappearingTimerRefreshNotifier._();

  final _controller = StreamController<String>.broadcast();

  Stream<String> get onChanged => _controller.stream;

  void notify(String conversationId) {
    if (!_controller.isClosed) {
      _controller.add(conversationId);
    }
  }
}
