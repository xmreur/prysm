import 'dart:async';

class MessageModifyUpdate {
  final String targetMessageId;
  final String action;
  final String? newText;
  final int modifiedAt;

  const MessageModifyUpdate({
    required this.targetMessageId,
    required this.action,
    this.newText,
    required this.modifiedAt,
  });

  bool get isDelete => action == 'delete';
  bool get isEdit => action == 'edit';
}

class MessageModifyRefreshNotifier {
  MessageModifyRefreshNotifier._();
  static final MessageModifyRefreshNotifier instance =
      MessageModifyRefreshNotifier._();

  final _controller = StreamController<MessageModifyUpdate>.broadcast();

  Stream<MessageModifyUpdate> get onModifyChanged => _controller.stream;

  void notify(MessageModifyUpdate update) {
    if (!_controller.isClosed) {
      _controller.add(update);
    }
  }
}
