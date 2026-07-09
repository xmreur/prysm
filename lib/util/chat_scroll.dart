import 'dart:async';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:prysm/ui/chat/prysm_chat_message_list.dart';

Future<void> scrollChatToBottom(
  PrysmChatMessageList controller, {
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

void scheduleScrollChatToBottom(
  PrysmChatMessageList controller, {
  bool animated = false,
  required bool Function() isMounted,
}) {
  SchedulerBinding.instance.addPostFrameCallback((_) {
    if (!isMounted()) return;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!isMounted()) return;
      unawaited(scrollChatToBottom(controller, animated: animated));
    });
  });
}

bool isChatScrolledToBottom(
  ScrollController controller, {
  double threshold = 48,
}) {
  if (!controller.hasClients) return true;
  final position = controller.position;
  return position.pixels >= position.maxScrollExtent - threshold;
}
