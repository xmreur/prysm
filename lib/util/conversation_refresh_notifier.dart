import 'dart:async';

/// Fired when inbound messages are stored so the sidebar can refresh without polling.
class ConversationRefreshNotifier {
  ConversationRefreshNotifier._();
  static final ConversationRefreshNotifier instance = ConversationRefreshNotifier._();

  final _controller = StreamController<void>.broadcast();

  Stream<void> get onRefresh => _controller.stream;

  void notifyInboundMessage() {
    if (!_controller.isClosed) {
      _controller.add(null);
    }
  }

  void dispose() {
    _controller.close();
  }
}
