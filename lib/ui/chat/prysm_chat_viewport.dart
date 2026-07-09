import 'package:flutter/widgets.dart';
import 'package:prysm/models/chat/prysm_message.dart';
import 'package:prysm/theme/prysm_style_scope.dart';
import 'package:prysm/ui/chat/prysm_chat_list.dart';
import 'package:prysm/ui/chat/prysm_chat_message_list.dart';

/// Shared chat layout: message list + optional composer / blocked banner.
class PrysmChatViewport extends StatelessWidget {
  const PrysmChatViewport({
    required this.messages,
    required this.scrollController,
    required this.itemBuilder,
    this.onLoadMore,
    this.showJumpToBottom = true,
    this.onStickToBottomChanged,
    this.composer,
    this.blockedBanner,
    super.key,
  });

  final PrysmChatMessageList messages;
  final ScrollController scrollController;
  final Widget Function(BuildContext context, Message message, int index)
      itemBuilder;
  final Future<void> Function()? onLoadMore;
  final bool showJumpToBottom;
  final ValueChanged<bool>? onStickToBottomChanged;
  final Widget? composer;
  final Widget? blockedBanner;

  @override
  Widget build(BuildContext context) {
    final tokens = context.prysmStyle.tokens;
    return ColoredBox(
      color: tokens.background,
      child: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: PrysmChatList(
                controller: messages,
                scrollController: scrollController,
                onLoadMore: onLoadMore,
                showJumpToBottom: showJumpToBottom,
                onStickToBottomChanged: onStickToBottomChanged,
                itemBuilder: itemBuilder,
              ),
            ),
            if (blockedBanner != null)
              blockedBanner!
            else if (composer != null)
              composer!,
          ],
        ),
      ),
    );
  }
}
