import 'package:prysm/models/chat/prysm_message.dart';

typedef ScrollToIndexFn = Future<void> Function(
  int index, {
  Duration duration,
  double alignment,
});

typedef ScrollToMessageIdFn = Future<void> Function(
  String messageId, {
  Duration duration,
  double alignment,
});

/// In-memory message list (replaces InMemoryChatController).
class PrysmChatMessageList {
  PrysmChatMessageList({List<PrysmMessage>? messages})
      : _messages = List.of(messages ?? []);

  final List<PrysmMessage> _messages;
  ScrollToIndexFn? _scrollToIndex;
  ScrollToMessageIdFn? _scrollToMessageId;

  List<PrysmMessage> get messages => List.unmodifiable(_messages);

  void attachScrollMethods({
    required ScrollToIndexFn scrollToIndex,
    required ScrollToMessageIdFn scrollToMessageId,
  }) {
    _scrollToIndex = scrollToIndex;
    _scrollToMessageId = scrollToMessageId;
  }

  void detachScrollMethods() {
    _scrollToIndex = null;
    _scrollToMessageId = null;
  }

  Future<void> scrollToIndex(
    int index, {
    Duration duration = const Duration(milliseconds: 250),
    double alignment = 0,
  }) {
    return _scrollToIndex?.call(
          index,
          duration: duration,
          alignment: alignment,
        ) ??
        Future.value();
  }

  Future<void> scrollToMessage(
    String messageId, {
    Duration duration = const Duration(milliseconds: 250),
    double alignment = 0,
  }) {
    return _scrollToMessageId?.call(
          messageId,
          duration: duration,
          alignment: alignment,
        ) ??
        Future.value();
  }

  void insertMessage(PrysmMessage message, {required int index}) {
    if (_messages.any((m) => m.id == message.id)) return;
    if (index < 0 || index > _messages.length) {
      _messages.add(message);
    } else {
      _messages.insert(index, message);
    }
  }

  void insertAllMessages(List<PrysmMessage> batch, {required int index}) {
    final filtered =
        batch.where((m) => !_messages.any((e) => e.id == m.id)).toList();
    if (filtered.isEmpty) return;
    _messages.insertAll(index.clamp(0, _messages.length), filtered);
  }

  void updateMessage(PrysmMessage old, PrysmMessage updated) {
    final i = _messages.indexWhere((m) => m.id == old.id);
    if (i >= 0) _messages[i] = updated;
  }

  void removeMessage(PrysmMessage message) {
    _messages.removeWhere((m) => m.id == message.id);
  }
}

typedef InMemoryChatController = PrysmChatMessageList;
