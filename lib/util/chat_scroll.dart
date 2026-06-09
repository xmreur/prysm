import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_chat_core/flutter_chat_core.dart';

/// Scrolls the chat list so the latest message is anchored at the bottom.
Future<void> scrollChatToBottom(
  InMemoryChatController controller, {
  bool animated = false,
}) async {
  final messages = controller.messages;
  if (messages.isEmpty) return;

  await controller.scrollToIndex(
    messages.length - 1,
    duration: animated ? const Duration(milliseconds: 200) : Duration.zero,
    alignment: 1.0,
  );
}

/// Waits two frames so bubble layout settles, then scrolls to the bottom.
void scheduleScrollChatToBottom(
  InMemoryChatController controller, {
  bool animated = false,
  required bool Function() isMounted,
}) {
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!isMounted()) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!isMounted()) return;
      unawaited(scrollChatToBottom(controller, animated: animated));
    });
  });
}

/// Returns true when the list is within [threshold] px of the bottom.
bool isChatScrolledToBottom(
  ScrollController controller, {
  double threshold = 48,
}) {
  if (!controller.hasClients) return true;
  final position = controller.position;
  return position.pixels >= position.maxScrollExtent - threshold;
}
