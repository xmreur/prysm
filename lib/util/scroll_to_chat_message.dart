import 'package:flutter_chat_core/flutter_chat_core.dart';

/// Scrolls the chat list until [messageId] is visible, loading older pages as needed.
Future<bool> scrollToChatMessage({
  required InMemoryChatController controller,
  required String messageId,
  required Future<bool> Function() loadMore,
  int maxAttempts = 40,
}) async {
  for (var attempt = 0; attempt < maxAttempts; attempt++) {
    final messages = controller.messages;
    final index = messages.indexWhere((m) => m.id == messageId);
    if (index >= 0) {
      await controller.scrollToIndex(
        index,
        duration: const Duration(milliseconds: 250),
        alignment: 0.5,
      );
      return true;
    }

    final loaded = await loadMore();
    if (!loaded) return false;
  }
  return false;
}
