import 'dart:async';

/// Fired when PrysmServer stores an inbound chat message so open chats can
/// update immediately without waiting for the DB poll loop.
class InboundMessageEvent {
  final Map<String, dynamic> row;
  final String? groupId;
  final String senderId;
  final String receiverId;

  const InboundMessageEvent({
    required this.row,
    required this.groupId,
    required this.senderId,
    required this.receiverId,
  });

  factory InboundMessageEvent.fromRow(Map<String, dynamic> row) {
    return InboundMessageEvent(
      row: row,
      groupId: row['groupId'] as String?,
      senderId: row['senderId'] as String,
      receiverId: row['receiverId'] as String,
    );
  }
}

class InboundMessageNotifier {
  InboundMessageNotifier._();
  static final InboundMessageNotifier instance = InboundMessageNotifier._();

  StreamController<InboundMessageEvent>? _controller;

  StreamController<InboundMessageEvent> get _ensureController {
    return _controller ??= StreamController<InboundMessageEvent>.broadcast();
  }

  Stream<InboundMessageEvent> get onInboundMessage => _ensureController.stream;

  void notify(InboundMessageEvent event) {
    final controller = _controller;
    if (controller != null && !controller.isClosed) {
      controller.add(event);
    }
  }

  /// Clears stream state between tests.
  void resetForTest() {
    _controller?.close();
    _controller = null;
  }
}
