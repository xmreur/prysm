import 'dart:async';

/// Fired when a message is inserted locally (MessagesDb.insertMessage) so
/// open chats can react without polling. Re-exported by
/// MessagesDb.onMessageInserted for compatibility -- ChatService keeps
/// listening through that re-export unchanged. Mirrors the
/// InboundMessageNotifier/ConversationRefreshNotifier singleton-bus pattern.
class MessageInsertBus {
  MessageInsertBus._();
  static final MessageInsertBus instance = MessageInsertBus._();

  StreamController<Map<String, dynamic>>? _controller;

  StreamController<Map<String, dynamic>> get _ensureController {
    return _controller ??= StreamController<Map<String, dynamic>>.broadcast();
  }

  Stream<Map<String, dynamic>> get onMessageInserted => _ensureController.stream;

  void notify(Map<String, dynamic> row) {
    final controller = _controller;
    if (controller != null && !controller.isClosed) {
      controller.add(row);
    }
  }

  /// Clears stream state between tests.
  void resetForTest() {
    _controller?.close();
    _controller = null;
  }
}
