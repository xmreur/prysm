import 'package:flutter/material.dart';
import 'package:prysm/screens/message_composer.dart';
import 'package:prysm/screens/widgets/contact_avatar.dart';
import 'package:prysm/screens/widgets/jump_to_bottom_fab.dart';
import 'package:prysm/util/chat_scroll.dart';
import 'package:prysm/util/decoy_session_data.dart';
import 'package:uuid/uuid.dart';

/// Read-only-looking chat for panic decoy sessions. Messages stay in memory only.
class DecoyChatScreen extends StatefulWidget {
  final String title;
  final String? avatarName;
  final String? avatarBase64;
  final bool isGroup;
  final List<DecoyMessage> initialMessages;
  final VoidCallback? onCloseChat;

  const DecoyChatScreen({
    required this.title,
    this.avatarName,
    this.avatarBase64,
    this.isGroup = false,
    required this.initialMessages,
    this.onCloseChat,
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
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        leading: widget.onCloseChat != null
            ? IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: widget.onCloseChat,
              )
            : null,
        title: Row(
          children: [
            ContactAvatar(
              name: widget.avatarName ?? widget.title,
              avatarBase64: widget.avatarBase64,
              radius: 18,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.title,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (widget.isGroup)
                    Text(
                      'Group',
                      style: TextStyle(fontSize: 12, color: theme.hintColor),
                    ),
                ],
              ),
            ),
          ],
        ),
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
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                itemCount: _messages.length,
                itemBuilder: (context, index) {
                  final msg = _messages[index];
                  return _DecoyMessageBubble(message: msg, isGroup: widget.isGroup);
                },
              ),
            ),
          ),
          MessageComposer(
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
    final theme = Theme.of(context);
    final isMe = message.isMe;
    final time = DateTime.fromMillisecondsSinceEpoch(message.createdAt);
    final timeString =
        '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';

    final bubbleColor = isMe
        ? theme.colorScheme.primary.withAlpha(225)
        : theme.colorScheme.secondary.withAlpha(225);
    final textColor = isMe
        ? theme.colorScheme.onPrimary
        : theme.colorScheme.onSecondary;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment:
            isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: [
          Flexible(
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
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: bubbleColor,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        message.text,
                        style: TextStyle(color: textColor, fontSize: 14),
                      ),
                      const SizedBox(height: 4),
                      Align(
                        alignment: Alignment.centerRight,
                        child: Text(
                          timeString,
                          style: TextStyle(
                            fontSize: 10,
                            color: textColor.withAlpha(180),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
