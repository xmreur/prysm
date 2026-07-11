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
import 'package:prysm/ui/chat/prysm_chat_message_list.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:prysm/crypto/wire.dart';
import 'package:prysm/database/self_messages_db.dart';
import 'package:prysm/screens/widgets/deleted_message_bubble.dart';
import 'package:prysm/screens/widgets/file_attachment_bubble.dart';
import 'package:prysm/screens/widgets/image_message_bubble.dart';
import 'package:prysm/screens/widgets/linked_message_text.dart';
import 'package:prysm/screens/widgets/prysm_chat_drop_target.dart';
import 'package:prysm/screens/widgets/voice_message_bubble.dart';
import 'package:prysm/services/file_attachment_resolver.dart';
import 'package:prysm/services/image_attachment_cache.dart';
import 'package:prysm/services/detached_chat_client.dart';
import 'package:prysm/services/self_chat_service.dart';
import 'package:prysm/util/chat_attachment_ingress.dart';
import 'package:prysm/theme/prysm_theme.dart';
import 'package:prysm/ui/chat/prysm_chat_composer_column.dart';
import 'package:prysm/ui/chat/prysm_chat_list.dart';
import 'package:prysm/ui/chat/prysm_date_header.dart';
import 'package:prysm/ui/prysm_scaffold.dart';
import 'package:prysm/util/chat_scroll.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/logging.dart';
import 'package:prysm/util/message_modify_policy.dart';
import 'package:prysm/util/waveform_extractor.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

class SelfChatScreen extends StatefulWidget {
  final String userId;
  final String userName;
  final String? avatarBase64;
  final KeyManager keyManager;
  final VoidCallback onCloseChat;
  final VoidCallback reloadSidebar;
  final DetachedChatClient? detachedClient;

  const SelfChatScreen({
    required this.userId,
    required this.userName,
    this.avatarBase64,
    required this.keyManager,
    required this.onCloseChat,
    required this.reloadSidebar,
    this.detachedClient,
    super.key,
  });

  @override
  State<SelfChatScreen> createState() => _SelfChatScreenState();
}

class _SelfChatScreenState extends State<SelfChatScreen> {
  late final SelfChatService _service;
  
  final _messages = InMemoryChatController();
  final _scrollController = ScrollController();

  bool _stickToBottom = true;
  bool _loading = false;
  bool _hasMore = true;
  int? _oldestTimestamp;
  String? _oldestMessageId;
  StreamSubscription? _detachedInboundSub;

  Future<List<Message>> _decryptForDisplay(
    List<Map<String, dynamic>> rows,
  ) async {
    if (widget.detachedClient != null) {
      return widget.detachedClient!.decryptRows(rows);
    }
    return _service.decryptMessages(rows);
  }

  @override
  void initState() {
    super.initState();
    
    _service = SelfChatService(
      userId: widget.userId,
      keyManager: widget.keyManager,
    );
    _scrollController.addListener(_onListScroll);
    if (widget.detachedClient != null) {
      _detachedInboundSub =
          widget.detachedClient!.onInboundMessages.listen((messages) {
        if (!mounted) return;
        setState(() {
          final existingIds = _messages.messages.map((m) => m.id).toSet();
          for (final msg in messages) {
            if (!existingIds.contains(msg.id)) {
              _messages.insertMessage(msg, index: _messages.messages.length);
            }
          }
        });
        _scheduleScrollToBottomAfterSend();
      });
    }
    _loadInitialMessages();
  }

  @override
  void dispose() {
    _detachedInboundSub?.cancel();
    _scrollController.removeListener(_onListScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onListScroll() {
    final atBottom = isChatScrolledToBottom(_scrollController);
    if (atBottom == _stickToBottom) return;
    setState(() => _stickToBottom = atBottom);
  }

  Future<void> _loadInitialMessages() async {
    await _loadMoreMessages();
    if (mounted && _messages.messages.isNotEmpty) {
      scheduleScrollChatToBottom(_messages, isMounted: () => mounted);
    }
  }

  Future<void> _loadMoreMessages() async {
    if (_loading || !_hasMore) return;
    _loading = true;

    final batch = await _service.loadMessagesBatch(
      limit: 20,
      beforeTimestamp: _oldestTimestamp,
      beforeId: _oldestMessageId,
    );

    if (!mounted) return;

    if (batch.length < 20) {
      _hasMore = false;
      _loading = false;
      if (batch.isEmpty) return;
    }

    final sorted = List<Map<String, dynamic>>.from(batch)
      ..sort(
        (a, b) => (a['timestamp'] as int).compareTo(b['timestamp'] as int),
      );

    final decrypted = await _decryptForDisplay(sorted);

    if (!mounted) return;

    setState(() {
      _messages.insertAllMessages(decrypted, index: 0);
      _oldestTimestamp = batch.last['timestamp'] as int;
      _oldestMessageId = batch.last['id'] as String;
      _loading = false;
    });
  }

  void _scheduleScrollToBottomAfterSend() {
    _stickToBottom = true;
    scheduleScrollChatToBottom(_messages, isMounted: () => mounted);
  }

  Future<void> _handleSendText(String text) async {
    if (!mounted) return;

    final messageId = const Uuid().v4();

    setState(() {
      _messages.insertMessage(
        TextMessage(
          authorId: widget.userId,
          createdAt: DateTime.now(),
          id: messageId,
          text: text,
        ),
        index: _messages.messages.length,
      );
    });
    _scheduleScrollToBottomAfterSend();

    if (widget.detachedClient != null) {
      await widget.detachedClient!.sendText(text: text, messageId: messageId);
      return;
    }

    await _service.sendTextMessage(text, messageId: messageId);
    widget.reloadSidebar();
  }

  Future<void> _sendFile(
    Uint8List bytes,
    String fileName,
    String type, {
    bool viewOnce = false,
  }) async {
    if (!mounted) return;

    final messageId = const Uuid().v4();

    setState(() {
      if (type == 'file') {
        _messages.insertMessage(
          FileMessage(
            authorId: widget.userId,
            createdAt: DateTime.now(),
            id: messageId,
            name: fileName,
            size: bytes.length,
            source: base64Encode(bytes),
          ),
          index: _messages.messages.length,
        );
      } else if (type == 'image') {
        _messages.insertMessage(
          ImageMessage(
            authorId: widget.userId,
            createdAt: DateTime.now(),
            id: messageId,
            size: bytes.length,
            source:
                'data:${ImageAttachmentCache.sniffImageMimeType(bytes)};base64,${base64Encode(bytes)}',
            metadata: viewOnce ? {'viewOnce': true, 'viewed': false} : null,
          ),
          index: _messages.messages.length,
        );
      }
    });
    _scheduleScrollToBottomAfterSend();

    if (widget.detachedClient != null) {
      await widget.detachedClient!.sendFile(
        bytes: bytes,
        fileName: fileName,
        type: type,
        messageId: messageId,
        viewOnce: viewOnce,
      );
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

  Future<void> _handleSendVoice(Uint8List bytes, int durationMs) async {
    if (!mounted) return;

    final messageId = const Uuid().v4();
    final cacheDir = await getTemporaryDirectory();
    final cachePath = '${cacheDir.path}/voice_cache_$messageId.wav';
    await File(cachePath).writeAsBytes(bytes);
    final peaks = WaveformExtractor.extractPeaks(bytes);
    final waveformMeta = WaveformExtractor.encodePeaks(peaks);

    if (!mounted) return;

    setState(() {
      _messages.insertMessage(
        FileMessage(
          authorId: widget.userId,
          createdAt: DateTime.now(),
          id: messageId,
          name: 'voice_message.wav',
          size: bytes.length,
          source: 'audio:$durationMs:$cachePath',
          metadata: {'waveform': waveformMeta},
        ),
        index: _messages.messages.length,
      );
    });
    _scheduleScrollToBottomAfterSend();

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

  Future<void> _deleteMessage(Message message) async {
    await SelfMessagesDb.softDelete(message.id);
    if (!mounted) return;
    setState(() {
      _messages.updateMessage(message, markMessageDeleted(message));
    });
    widget.reloadSidebar();
  }

  void _showMessageMenu(BuildContext context, Message message) {
    if (isMessageDeleted(message)) return;

    showPrysmSheet(
      context: context,
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
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
                  PrysmPageRoute(page: _ViewOnceScreen(imageBytes: decryptedBytes),
                  ),
                );
                await SelfMessagesDb.markViewOnceViewed(message.id);
                if (!mounted) return;
                setState(() {
                  _messages.updateMessage(
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
      body: PrysmChatDropTarget(
        onFileDropped: _handleDroppedFile,
        child: Column(
          children: [
            Expanded(
              child: PrysmChatList(
                controller: _messages,
                scrollController: _scrollController,
                onLoadMore: _loadMoreMessages,
                onStickToBottomChanged: (atBottom) {
                  _stickToBottom = atBottom;
                },
                itemBuilder: (context, message, index) {
                  final showHeader = shouldShowChatDateHeader(
                    _messages.messages,
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

                  return Column(
                    children: [
                      if (showHeader) PrysmDateHeader(date: msgDate),
                      GestureDetector(
                        onLongPress: () => _showMessageMenu(context, message),
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
                    ],
                  );
                },
              ),
            ),
            PrysmChatComposerColumn(
              draftKey: 'self:${widget.userId}',
              onSendText: _handleSendText,
              onSendImage: _handleSendImage,
              onSendFile: _handleSendFile,
              onSendVoice: _handleSendVoice,
            ),
          ],
        ),
      ),
    );
  }
}

class _ViewOnceScreen extends StatelessWidget {
  final Uint8List imageBytes;

  const _ViewOnceScreen({required this.imageBytes});

  @override
  Widget build(BuildContext context) {
    return PrysmPage(
      backgroundColor: const Color(0xFF000000),
      leading: PrysmIconButton(
        icon: PrysmIcons.close,
        color: const Color(0xB3FFFFFF),
        onPressed: () => Navigator.of(context).pop(),
      ),
      body: Center(
        child: InteractiveViewer(
          child: Image.memory(imageBytes, fit: BoxFit.contain),
        ),
      ),
    );
  }
}
