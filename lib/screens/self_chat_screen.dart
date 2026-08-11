import 'package:flutter/widgets.dart';
import 'package:flutter/foundation.dart';
import 'package:prysm/ui/core/prysm_button.dart';
import 'package:prysm/ui/core/prysm_icons.dart';
import 'package:prysm/ui/core/prysm_app.dart';
import 'package:prysm/ui/core/prysm_list_row.dart';
import 'package:prysm/ui/core/prysm_toast.dart';
import 'package:prysm/theme/prysm_style_scope.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:prysm/models/chat/prysm_message.dart';
import 'package:image_picker/image_picker.dart';
import 'package:prysm/crypto/wire.dart';
import 'package:prysm/database/self_messages_db.dart';
import 'package:prysm/screens/widgets/deleted_message_bubble.dart';
import 'package:prysm/screens/widgets/message_copy_action.dart';
import 'package:prysm/screens/widgets/file_attachment_bubble.dart';
import 'package:prysm/screens/widgets/image_message_bubble.dart';
import 'package:prysm/screens/widgets/linked_message_text.dart';
import 'package:prysm/screens/widgets/prysm_chat_drop_target.dart';
import 'package:prysm/screens/widgets/view_once_image_screen.dart';
import 'package:prysm/screens/widgets/voice_message_bubble.dart';
import 'package:prysm/services/file_attachment_resolver.dart';
import 'package:prysm/services/detached_chat_client.dart';
import 'package:prysm/services/chat_screen_controller.dart';
import 'package:prysm/services/self_chat_service.dart';
import 'package:prysm/util/chat_attachment_ingress.dart';
import 'package:prysm/theme/prysm_theme.dart';
import 'package:prysm/ui/chat/prysm_chat_composer_column.dart';
import 'package:prysm/ui/chat/prysm_constrained_composer.dart';
import 'package:prysm/ui/chat/prysm_chat_list.dart';
import 'package:prysm/ui/chat/chat_search_bar.dart';
import 'package:prysm/models/conversation.dart';
import 'package:prysm/util/scroll_to_chat_message.dart';
import 'package:prysm/ui/chat/prysm_date_header.dart';
import 'package:prysm/ui/prysm_scaffold.dart';
import 'package:prysm/util/chat_scroll.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/logging.dart';
import 'package:prysm/util/message_modify_policy.dart';
import 'package:url_launcher/url_launcher.dart';

class SelfChatScreen extends StatefulWidget {
  final String userId;
  final String userName;
  final String? avatarBase64;
  final KeyManager keyManager;
  final VoidCallback onCloseChat;
  final VoidCallback reloadSidebar;
  final DetachedChatClient? detachedClient;
  final String? initialScrollToMessageId;

  const SelfChatScreen({
    required this.userId,
    required this.userName,
    this.avatarBase64,
    required this.keyManager,
    required this.onCloseChat,
    required this.reloadSidebar,
    this.detachedClient,
    this.initialScrollToMessageId,
    super.key,
  });

  @override
  State<SelfChatScreen> createState() => _SelfChatScreenState();
}

class _SelfChatScreenState extends State<SelfChatScreen> {
  late final SelfChatService _service;
  late final ChatScreenController _controller;
  final _scrollController = ScrollController();

  StreamSubscription? _detachedInboundSub;
  String? _highlightedMessageId;
  Timer? _highlightTimer;
  bool _showChatSearch = false;
  String _chatHighlightQuery = '';

  Future<List<Message>> _decryptForDisplay(
    List<Map<String, dynamic>> rows,
  ) async {
    if (widget.detachedClient != null) {
      return widget.detachedClient!.decryptRows(rows);
    }
    return _service.decryptMessages(rows);
  }

  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();

    _service = SelfChatService(
      userId: widget.userId,
      keyManager: widget.keyManager,
    );
    // Self-chat wiring of the shared Fase 6B controller: pagination,
    // stick-to-bottom scroll and the optimistic-insert send pipeline are
    // shared with DM/group; typing, reactions and read receipts stay
    // unwired (peer-only concepts — a self-chat has no peer).
    _controller = ChatScreenController(
      localUserId: widget.userId,
      draftKey: 'self:${widget.userId}',
      listScrollController: _scrollController,
      isMounted: () => mounted,
      fetchMessageBatch: ({beforeTimestamp, beforeId}) =>
          _service.loadMessagesBatch(
        limit: 20,
        beforeTimestamp: beforeTimestamp,
        beforeId: beforeId,
      ),
      decryptForDisplay: _decryptForDisplay,
      // Self-chat has no send-side message cache to seed (DM-only concept).
      seedNewestTimestamp: (_) {},
      onToast: (msg) => showPrysmToast(context, msg),
      fileMessageSource: base64Encode,
      dispatchText: _dispatchText,
      dispatchFile: _dispatchFile,
      dispatchVoice: _dispatchVoice,
    );
    _controller.addListener(_onControllerChanged);
    _scrollController.addListener(_controller.onListScroll);
    if (widget.detachedClient != null) {
      _detachedInboundSub =
          widget.detachedClient!.onInboundMessages.listen((messages) {
        if (!mounted) return;
        setState(() {
          final existingIds =
              _controller.messages.messages.map((m) => m.id).toSet();
          for (final msg in messages) {
            if (!existingIds.contains(msg.id)) {
              _controller.messages.insertMessage(
                msg,
                index: _controller.messages.messages.length,
              );
            }
          }
        });
        _controller.scheduleScrollToBottomAfterSend();
      });
    }
    _loadInitialMessages();
  }

  @override
  void didUpdateWidget(covariant SelfChatScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    final scrollId = widget.initialScrollToMessageId;
    if (scrollId != null && scrollId != oldWidget.initialScrollToMessageId) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(_scrollToMessage(scrollId));
      });
    }
  }

  @override
  void dispose() {
    _highlightTimer?.cancel();
    _detachedInboundSub?.cancel();
    _scrollController.removeListener(_controller.onListScroll);
    _scrollController.dispose();
    _controller.removeListener(_onControllerChanged);
    _controller.dispose();
    super.dispose();
  }

  Future<void> _loadInitialMessages() async {
    await _controller.loadMoreMessages();
    if (mounted && _controller.messages.messages.isNotEmpty) {
      scheduleScrollChatToBottom(
        _controller.messages,
        isMounted: () => mounted,
      );
    }
    final initialId = widget.initialScrollToMessageId;
    if (initialId != null && mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(_scrollToMessage(initialId));
      });
    }
  }

  Future<void> _scrollToMessage(String messageId) async {
    final found = await scrollToChatMessage(
      controller: _controller.messages,
      messageId: messageId,
      loadMore: () async {
        if (!_controller.hasMore || _controller.loading) return false;
        final countBefore = _controller.messages.messages.length;
        await _controller.loadMoreMessages();
        return _controller.messages.messages.length > countBefore;
      },
    );
    if (!mounted) return;
    if (found) {
      setState(() => _highlightedMessageId = messageId);
      _highlightTimer?.cancel();
      _highlightTimer = Timer(const Duration(seconds: 2), () {
        if (mounted) {
          setState(() => _highlightedMessageId = null);
        }
      });
    }
  }

  // ---- Send dispatch (screen-owned transport; the optimistic-insert
  // mechanics live in the controller). reloadSidebar fires exactly where
  // the pre-migration code fired it: after every service send, and after
  // detached file sends only (detached text/voice never reloaded).

  Future<void> _dispatchText({
    required String text,
    required String messageId,
    String? replyToId,
  }) async {
    if (widget.detachedClient != null) {
      await widget.detachedClient!.sendText(text: text, messageId: messageId);
      return;
    }
    await _service.sendTextMessage(text, messageId: messageId);
    widget.reloadSidebar();
  }

  Future<void> _dispatchFile({
    required Uint8List bytes,
    required String fileName,
    required String type,
    required String messageId,
    String? replyToId,
    required bool viewOnce,
  }) async {
    if (widget.detachedClient != null) {
      await widget.detachedClient!.sendFile(
        bytes: bytes,
        fileName: fileName,
        type: type,
        messageId: messageId,
        viewOnce: viewOnce,
      );
      widget.reloadSidebar();
      return;
    }
    await _service.sendFileMessage(
      bytes,
      fileName,
      type,
      messageId: messageId,
      viewOnce: viewOnce,
    );
    widget.reloadSidebar();
  }

  Future<void> _dispatchVoice({
    required Uint8List bytes,
    required int durationMs,
    required String messageId,
    String? replyToId,
    required String cachePath,
  }) async {
    if (widget.detachedClient != null) {
      await widget.detachedClient!.sendVoice(
        bytes: bytes,
        durationMs: durationMs,
        messageId: messageId,
      );
      return;
    }
    await _service.sendFileMessage(
      bytes,
      'voice_message.wav',
      'audio',
      messageId: messageId,
    );
    widget.reloadSidebar();
  }

  Future<void> _handleSendText(String text) => _controller.handleSendText(text);

  Future<void> _sendFile(
    Uint8List bytes,
    String fileName,
    String type, {
    bool viewOnce = false,
  }) =>
      _controller.sendFile(bytes, fileName, type, viewOnce: viewOnce);

  Future<void> _handleSendImage() async {
    final picker = ImagePicker();
    final pickedFile = await picker.pickImage(
      source: ImageSource.gallery,
      requestFullMetadata: true,
    );
    if (pickedFile == null) return;

    final bytes = await pickedFile.readAsBytes();
    if (!mounted) return;

    await ChatAttachmentIngress.sendLocalAttachment(
      context: context,
      bytes: bytes,
      fileName: pickedFile.name,
      sendFile: _sendFile,
      forceImageFlow: true,
    );
  }

  Future<void> _handleSendFile() async {
    final result = await FilePicker.platform.pickFiles(withData: true);
    if (result == null || result.files.isEmpty) return;

    final file = result.files.first;
    if (file.bytes == null) return;
    if (!mounted) return;

    await ChatAttachmentIngress.sendLocalAttachment(
      context: context,
      bytes: file.bytes!,
      fileName: file.name,
      sendFile: _sendFile,
    );
  }

  Future<void> _handleDroppedFile(String path, String name) async {
    try {
      final bytes = await File(path).readAsBytes();
      if (!mounted) return;
      await ChatAttachmentIngress.sendLocalAttachment(
        context: context,
        bytes: bytes,
        fileName: name,
        sendFile: _sendFile,
      );
    } catch (e) {
      if (mounted) {
        showPrysmToast(context, 'Could not read dropped file: $e');
      }
    }
  }

  Future<void> _handleSendVoice(Uint8List bytes, int durationMs) =>
      _controller.sendVoice(bytes, durationMs);

  Future<void> _deleteMessage(Message message) async {
    await SelfMessagesDb.softDelete(message.id);
    if (!mounted) return;
    setState(() {
      _controller.messages.updateMessage(message, markMessageDeleted(message));
    });
    widget.reloadSidebar();
  }

  void _showMessageMenu(BuildContext context, Message message) {
    if (isMessageDeleted(message)) return;

    final text = messageCopyText(message);
    showPrysmSheet(
      context: context,
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (text.isNotEmpty) copyMessageTile(context: context, text: text),
          PrysmListRow(
            leading: const Icon(PrysmIcons.deleteOutline),
            title: 'Delete',
            onTap: () {
              Navigator.pop(ctx);
              _deleteMessage(message);
            },
          ),
        ],
      ),
    );
  }

  Future<void> _openUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Widget _displayChildForMessage(Message message, Widget child) {
    if (isMessageDeleted(message)) {
      return DeletedMessageBubble(
        isSentByMe: true,
        createdAt: message.createdAt ?? DateTime.now(),
      );
    }
    return child;
  }

  Widget _textMessageBuilder(
    BuildContext context,
    TextMessage message,
    int index, {
    required bool isSentByMe,
  }) {
    final msgDate = message.createdAt ?? DateTime.now();
    final timeString =
        '${msgDate.hour.toString().padLeft(2, '0')}:${msgDate.minute.toString().padLeft(2, '0')}';

    final tokens = context.prysmTokens;
    return IntrinsicWidth(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: tokens.bubbleSent,
          borderRadius: prysmBubbleBorderRadius(isSentByMe: true),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            LinkedMessageText(
              text: message.text,
              textColor: tokens.onAccent,
              fontSize: 14,
              onOpenUrl: _openUrl,
              highlightQuery:
                  _showChatSearch ? _chatHighlightQuery : null,
            ),
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerRight,
              child: Text(
                timeString,
                style: TextStyle(
                  fontSize: 10,
                  color: tokens.onAccent.withValues(alpha: 0.75),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _imageMessageBuilder(
    BuildContext context,
    ImageMessage message,
    int index, {
    required bool isSentByMe,
  }) {
    final msgDate = message.createdAt ?? DateTime.now();
    final timeString =
        '${msgDate.hour.toString().padLeft(2, '0')}:${msgDate.minute.toString().padLeft(2, '0')}';
    final isViewOnce = message.metadata?['viewOnce'] == true;
    final isViewed = message.metadata?['viewed'] == true;

    if (isViewOnce && isViewed) {
      final muted = context.prysmStyle.tokens.textMuted;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Container(
            width: 200,
            height: 60,
            decoration: BoxDecoration(
              color: context.prysmStyle.tokens.surfaceElevated,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(PrysmIcons.timerOff, size: 20, color: muted),
                const SizedBox(width: 8),
                Text(
                  'Opened',
                  style: TextStyle(
                    color: muted,
                    fontStyle: FontStyle.italic,
                    fontSize: 14,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Text(
            timeString,
            style: TextStyle(
              fontSize: 10,
              color: context.prysmStyle.tokens.textSecondary,
            ),
          ),
        ],
      );
    }

    if (isViewOnce && !isViewed) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          GestureDetector(
            onTap: () async {
              try {
                final decryptedBytes =
                    await _service.decryptImageFromDb(message.id);
                if (!context.mounted) return;
                await Navigator.push(
                  context,
                  PrysmPageRoute(page: ViewOnceImageScreen(
                    imageBytes: decryptedBytes,
                    fit: BoxFit.contain,
                    title: null,
                    closeColor: const Color(0xB3FFFFFF),
                  ),
                  ),
                );
                await SelfMessagesDb.markViewOnceViewed(message.id);
                if (!mounted) return;
                setState(() {
                  _controller.messages.updateMessage(
                    message,
                    message.copyWith(
                      source: '',
                      metadata: const {'viewOnce': true, 'viewed': true},
                    ),
                  );
                });
              } catch (e) {
                Logging.error('View-once decrypt failed: $e', 'SelfChatScreen');
              }
            },
            child: Container(
              width: 200,
              height: 120,
              decoration: BoxDecoration(
                color: context.prysmStyle.tokens.accent.withAlpha(40),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    PrysmIcons.visibility,
                    color: context.prysmStyle.tokens.accent,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'View once',
                    style: TextStyle(
                      color: context.prysmStyle.tokens.accent,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            timeString,
            style: TextStyle(
              fontSize: 10,
              color: context.prysmStyle.tokens.textSecondary,
            ),
          ),
        ],
      );
    }

    return ImageMessageBubble(
      message: message,
      isSentByMe: true,
      timeString: timeString,
      tickWidget: const SizedBox.shrink(),
      decryptFromDb: () => _service.decryptImageFromDb(message.id),
    );
  }

  Widget _fileMessageBuilder(
    BuildContext context,
    FileMessage message,
    int index, {
    required bool isSentByMe,
  }) {
    if (message.name.contains('voice_message') ||
        message.source.startsWith('audio:')) {
      final msgDate = message.createdAt ?? DateTime.now();
      final timeString =
          '${msgDate.hour.toString().padLeft(2, '0')}:${msgDate.minute.toString().padLeft(2, '0')}';

      return VoiceMessageBubble(
        message: message,
        isSentByMe: true,
        timeString: timeString,
        tickWidget: const SizedBox.shrink(),
        decryptAudio: message.source.startsWith('audio:')
            ? null
            : (encryptedSource) => CryptoWire.decryptFile(
                  encryptedSource,
                  widget.keyManager.identity,
                ),
      );
    }

    final msgDate = message.createdAt ?? DateTime.now();
    final timeString =
        '${msgDate.hour.toString().padLeft(2, '0')}:${msgDate.minute.toString().padLeft(2, '0')}';

    return FileAttachmentBubble(
      fileName: message.name,
      fileSize: message.size,
      timeString: timeString,
      isSentByMe: true,
      tickWidget: const SizedBox.shrink(),
      resolveBytes: () => FileAttachmentResolver.resolve(
        message,
        keyManager: widget.keyManager,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PrysmPage(
      leading: PrysmIconButton(
        icon: PrysmIcons.arrowBack,
        onPressed: widget.onCloseChat,
      ),
      title: 'Chat with myself',
      subtitle: 'Notes to yourself',
      actions: [
        PrysmIconButton(
          icon: PrysmIcons.search,
          onPressed: () => setState(() {
            _showChatSearch = !_showChatSearch;
            if (!_showChatSearch) _chatHighlightQuery = '';
          }),
        ),
      ],
      bottom: _showChatSearch
          ? ChatSearchBar(
              conversationId: SelfConversation.conversationId,
              onClose: () => setState(() {
                _showChatSearch = false;
                _chatHighlightQuery = '';
              }),
              onQueryChanged: (query) =>
                  setState(() => _chatHighlightQuery = query),
              onResultSelected: (hit, _) {
                unawaited(_scrollToMessage(hit.messageId));
              },
            )
          : null,
      body: PrysmChatDropTarget(
        onFileDropped: _handleDroppedFile,
        child: LayoutBuilder(
          builder: (context, constraints) => Column(
            children: [
              Expanded(
                child: PrysmChatList(
                  controller: _controller.messages,
                  scrollController: _scrollController,
                  onLoadMore: _controller.loadMoreMessages,
                  onStickToBottomChanged: _controller.setStickToBottomSilently,
                  itemBuilder: (context, message, index) {
                    final showHeader = shouldShowChatDateHeader(
                      _controller.messages.messages,
                      index,
                    );
                    final msgDate = message.createdAt ?? DateTime.now();
                    Widget child;
                    if (message is TextMessage) {
                      child = _textMessageBuilder(
                        context,
                        message,
                        index,
                        isSentByMe: true,
                      );
                    } else if (message is ImageMessage) {
                      child = _imageMessageBuilder(
                        context,
                        message,
                        index,
                        isSentByMe: true,
                      );
                    } else if (message is FileMessage) {
                      child = _fileMessageBuilder(
                        context,
                        message,
                        index,
                        isSentByMe: true,
                      );
                    } else {
                      child = const SizedBox.shrink();
                    }
  
                    final isHighlighted = _highlightedMessageId == message.id;
                    final tokens = context.prysmStyle.tokens;
  
                    return Column(
                      children: [
                        if (showHeader) PrysmDateHeader(date: msgDate),
                        GestureDetector(
                          onLongPress: () => _showMessageMenu(context, message),
                          child: ColoredBox(
                            color: isHighlighted
                                ? Color.lerp(
                                    tokens.background,
                                    tokens.accentMuted,
                                    0.25,
                                  )!
                                : const Color(0x00000000),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 4),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.end,
                                children: [
                                  Flexible(
                                    child: _displayChildForMessage(message, child),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
              // Same keyboard-inset overflow as the 1:1 chat body: the
              // composer is a non-flex Column child laid out with unbounded
              // main-axis constraints, so constrain and scroll it instead of
              // overflowing.
              PrysmConstrainedComposer(
                maxHeight: constraints.maxHeight,
                composer: PrysmChatComposerColumn(
                  draftKey: 'self:${widget.userId}',
                  onSendText: _handleSendText,
                  onSendImage: _handleSendImage,
                  onSendFile: _handleSendFile,
                  onSendVoice: _handleSendVoice,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
