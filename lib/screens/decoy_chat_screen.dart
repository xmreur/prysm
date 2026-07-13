import 'package:flutter/widgets.dart';
import 'package:prysm/ui/core/prysm_icons.dart';
import 'package:prysm/ui/core/prysm_button.dart';
import 'package:prysm/screens/message_composer.dart';
import 'package:prysm/screens/widgets/contact_avatar.dart';
import 'package:prysm/screens/widgets/jump_to_bottom_fab.dart';
import 'package:prysm/util/chat_scroll.dart';
import 'package:prysm/util/decoy_session_data.dart';
import 'package:prysm/theme/prysm_style_scope.dart';
import 'package:prysm/ui/prysm_scaffold.dart';
import 'package:prysm/ui/chat/prysm_bubble_renderer.dart';
import 'package:uuid/uuid.dart';

/// Read-only-looking chat for panic decoy sessions. Messages stay in memory only.
class DecoyChatScreen extends StatefulWidget {
  final String conversationId;
  final String title;
  final String? avatarName;
  final String? avatarBase64;
  final bool isGroup;
  final List<DecoyMessage> initialMessages;
  final VoidCallback? onCloseChat;
  final Widget? torStatusAction;

  const DecoyChatScreen({
    required this.conversationId,
    required this.title,
    this.avatarName,
    this.avatarBase64,
    this.isGroup = false,
    required this.initialMessages,
    this.onCloseChat,
    this.torStatusAction,
    super.key,
  });

  @override
  State<DecoyChatScreen> createState() => _DecoyChatScreenState();
}

class _DecoyChatScreenState extends State<DecoyChatScreen> {
  late List<DecoyMessage> _messages;
  final _scrollController = ScrollController();
  bool _atBottom = true;

  @override
  void initState() {
    super.initState();
    _messages = List.of(widget.initialMessages);
    _scrollController.addListener(_onListScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
  }

  void _onListScroll() {
    final atBottom = isChatScrolledToBottom(_scrollController);
    if (atBottom == _atBottom) return;
    setState(() => _atBottom = atBottom);
  }

  void _scrollToBottom() {
    if (!_scrollController.hasClients) return;
    _atBottom = true;
    _scrollController.animateTo(
      _scrollController.position.maxScrollExtent,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
    if (mounted) setState(() {});
  }

  void _handleSend(String text) {
    setState(() {
      _messages.add(
        DecoyMessage(
          id: const Uuid().v4(),
          text: text,
          isMe: true,
          createdAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onListScroll);
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.prysmStyle.tokens;
    final style = context.prysmStyle;

    return PrysmPage(
      headerHeight: 70,
      leading: widget.onCloseChat != null
          ? PrysmIconButton(
              icon: PrysmIcons.chevronLeft,
              onPressed: widget.onCloseChat,
            )
          : null,
      actions: [
        if (widget.torStatusAction != null) widget.torStatusAction!,
      ],
      titleWidget: Row(
        children: [
          ContactAvatar(
            name: widget.avatarName ?? widget.title,
            avatarBase64: widget.avatarBase64,
            radius: 20,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  widget.title,
                  style: style.titleStyle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                if (widget.isGroup)
                  Text(
                    'Group',
                    style: style.captionStyle.copyWith(
                      color: tokens.textMuted,
                      fontWeight: FontWeight.w500,
                    ),
                  )
                else
                  Row(
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: tokens.textPrimary.withAlpha(100),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        'Offline',
                        style: style.captionStyle.copyWith(
                          color: tokens.textMuted,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: JumpToBottomFabOverlay(
              visible: !_atBottom && _messages.isNotEmpty,
              onPressed: _scrollToBottom,
              bottom: 16,
              child: ListView.builder(
                controller: _scrollController,
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                itemCount: _messages.length,
                itemBuilder: (context, index) {
                  final msg = _messages[index];
                  return _DecoyMessageBubble(
                    message: msg,
                    isGroup: widget.isGroup,
                  );
                },
              ),
            ),
          ),
          MessageComposer(
            draftKey: 'decoy:${widget.conversationId}',
            onSendText: _handleSend,
            onSendImage: () {},
            onSendFile: () {},
          ),
        ],
      ),
    );
  }
}

class _DecoyMessageBubble extends StatelessWidget {
  final DecoyMessage message;
  final bool isGroup;

  const _DecoyMessageBubble({
    required this.message,
    required this.isGroup,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = context.prysmStyle.tokens;
    final isMe = message.isMe;
    final time = DateTime.fromMillisecondsSinceEpoch(message.createdAt);
    final timeString =
        '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';

    final textColor = isMe ? tokens.onAccent : tokens.textPrimary;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Column(
        crossAxisAlignment:
            isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          if (isGroup && !isMe && message.senderName != null)
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 2),
              child: Text(
                message.senderName!,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: tokens.accent,
                ),
              ),
            ),
          IntrinsicWidth(
            child: PrysmBubbleRenderer(
              isSentByMe: isMe,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      message.text,
                      style: context.prysmStyle.bodyStyle.copyWith(
                        color: textColor,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Align(
                      alignment: Alignment.centerRight,
                      child: Text(
                        timeString,
                        style: context.prysmStyle.captionStyle.copyWith(
                          color: textColor.withValues(alpha: 0.7),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
