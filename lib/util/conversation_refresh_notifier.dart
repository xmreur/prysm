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

/// Fired when a message is edited by the remote peer so the chat UI can update it in-place.
class MessageEditNotifier {
  MessageEditNotifier._();
  static final MessageEditNotifier instance = MessageEditNotifier._();

  final _controller = StreamController<String>.broadcast();

  Stream<String> get onEdited => _controller.stream;

  void notifyEdited(String messageId, {String? groupId}) {
    if (!_controller.isClosed) {
      _controller.add('${groupId ?? ''}::$messageId');
    }
  }

  void dispose() {
    _controller.close();
  }
}
