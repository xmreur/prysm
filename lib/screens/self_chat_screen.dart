import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_chat_core/flutter_chat_core.dart';
import 'package:flutter_chat_ui/flutter_chat_ui.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:prysm/crypto/wire.dart';
import 'package:prysm/database/self_messages_db.dart';
import 'package:prysm/screens/widgets/contact_avatar.dart';
import 'package:prysm/screens/widgets/deleted_message_bubble.dart';
import 'package:prysm/screens/widgets/file_attachment_bubble.dart';
import 'package:prysm/screens/widgets/image_message_bubble.dart';
import 'package:prysm/screens/widgets/image_send_preview_screen.dart';
import 'package:prysm/screens/widgets/linked_message_text.dart';
import 'package:prysm/screens/widgets/prysm_chat_composer_overlay.dart';
import 'package:prysm/screens/widgets/voice_message_bubble.dart';
import 'package:prysm/services/file_attachment_resolver.dart';
import 'package:prysm/services/image_attachment_cache.dart';
import 'package:prysm/services/self_chat_service.dart';
import 'package:prysm/util/chat_scroll.dart';
import 'package:prysm/util/key_manager.dart';
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

  const SelfChatScreen({
    required this.userId,
    required this.userName,
    this.avatarBase64,
    required this.keyManager,
    required this.onCloseChat,
    required this.reloadSidebar,
    super.key,
  });

  @override
  State<SelfChatScreen> createState() => _SelfChatScreenState();
}

class _SelfChatScreenState extends State<SelfChatScreen> {
  late final SelfChatService _service;
  late final User _user;
  final _messages = InMemoryChatController();
  final _scrollController = ScrollController();

  bool _loading = false;
  bool _hasMore = true;
  int? _oldestTimestamp;
  String? _oldestMessageId;

  @override
  void initState() {
    super.initState();
    _user = User(id: widget.userId);
    _service = SelfChatService(
      userId: widget.userId,
      keyManager: widget.keyManager,
    );
    _scrollController.addListener(_onListScroll);
    _loadInitialMessages();
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onListScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onListScroll() {
    isChatScrolledToBottom(_scrollController);
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

    final decrypted = await _service.decryptMessages(sorted);

    if (!mounted) return;

    setState(() {
      _messages.insertAllMessages(decrypted, index: 0);
      _oldestTimestamp = batch.last['timestamp'] as int;
      _oldestMessageId = batch.last['id'] as String;
      _loading = false;
    });
  }

  void _scheduleScrollToBottomAfterSend() {
    scheduleScrollChatToBottom(_messages, isMounted: () => mounted);
  }

  Future<void> _handleSendText(String text) async {
    if (!mounted) return;

    final messageId = const Uuid().v4();

    setState(() {
      _messages.insertMessage(
        TextMessage(
          authorId: _user.id,
          createdAt: DateTime.now(),
          id: messageId,
          text: text,
        ),
        index: _messages.messages.length,
      );
    });
    _scheduleScrollToBottomAfterSend();

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
            authorId: _user.id,
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
            authorId: _user.id,
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

    var bytes = await pickedFile.readAsBytes();

    if (bytes.length > 500 * 1024) {
      try {
        bytes = await FlutterImageCompress.compressWithList(
          bytes,
          minHeight: 1080,
          minWidth: 1080,
          quality: 70,
        );
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Image compression failed, sending original.'),
            ),
          );
        }
      }
    }

    if (!mounted) return;

    final viewOnce = await ImageSendPreviewScreen.open(context, bytes);
    if (viewOnce == null || !mounted) return;

    await _sendFile(bytes, pickedFile.name, 'image', viewOnce: viewOnce);
  }

  Future<void> _handleSendFile() async {
    final result = await FilePicker.platform.pickFiles(withData: true);
    if (result == null || result.files.isEmpty) return;

    final file = result.files.first;
    if (file.bytes == null) return;
    await _sendFile(file.bytes!, file.name, 'file');
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
          authorId: _user.id,
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

    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Delete'),
              onTap: () {
                Navigator.pop(ctx);
                _deleteMessage(message);
              },
            ),
          ],
        ),
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
    MessageGroupStatus? groupStatus,
  }) {
    final msgDate = message.createdAt ?? DateTime.now();
    final timeString =
        '${msgDate.hour.toString().padLeft(2, '0')}:${msgDate.minute.toString().padLeft(2, '0')}';

    return IntrinsicWidth(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primary.withAlpha(225),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            LinkedMessageText(
              text: message.text,
              textColor: Theme.of(context).colorScheme.onPrimary,
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
                  color: Theme.of(context).colorScheme.onPrimary.withAlpha(200),
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
    MessageGroupStatus? groupStatus,
  }) {
    final msgDate = message.createdAt ?? DateTime.now();
    final timeString =
        '${msgDate.hour.toString().padLeft(2, '0')}:${msgDate.minute.toString().padLeft(2, '0')}';
    final isViewOnce = message.metadata?['viewOnce'] == true;
    final isViewed = message.metadata?['viewed'] == true;

    if (isViewOnce && isViewed) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Container(
            width: 200,
            height: 60,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.timer_off, size: 20, color: Colors.grey[500]),
                const SizedBox(width: 8),
                Text(
                  'Opened',
                  style: TextStyle(
                    color: Colors.grey[500],
                    fontStyle: FontStyle.italic,
                    fontSize: 14,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Text(timeString, style: TextStyle(fontSize: 10, color: Colors.grey[600])),
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
                  MaterialPageRoute(
                    builder: (_) =>
                        _ViewOnceScreen(imageBytes: decryptedBytes),
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
                debugPrint('View-once decrypt failed: $e');
              }
            },
            child: Container(
              width: 200,
              height: 120,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary.withAlpha(40),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.remove_red_eye,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'View once',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(timeString, style: TextStyle(fontSize: 10, color: Colors.grey[600])),
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
    MessageGroupStatus? groupStatus,
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
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: widget.onCloseChat,
        ),
        title: Row(
          children: [
            ContactAvatar(
              name: widget.userName,
              avatarBase64: widget.avatarBase64,
              radius: 18,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Chat with myself',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    'Notes to yourself',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).hintColor,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      body: SafeArea(
        child: Chat(
          chatController: _messages,
          currentUserId: widget.userId,
          theme: ChatTheme.fromThemeData(Theme.of(context)),
          resolveUser: (_) async => _user,
          onMessageSend: _handleSendText,
          builders: Builders(
            chatAnimatedListBuilder: (context, itemBuilder) {
              return ChatAnimatedList(
                scrollController: _scrollController,
                bottomPadding: 0,
                handleSafeArea: false,
                initialScrollToEndMode: InitialScrollToEndMode.none,
                itemBuilder: itemBuilder,
                onEndReached: () async {
                  await _loadMoreMessages();
                },
              );
            },
            chatMessageBuilder: (
              context,
              message,
              index,
              animation,
              child, {
              bool? isRemoved,
              required bool isSentByMe,
              MessageGroupStatus? groupStatus,
            }) {
              final msgDate = message.createdAt ?? DateTime.now();
              final currentDay =
                  DateTime(msgDate.year, msgDate.month, msgDate.day);

              DateTime? prevDay;
              if (index > 0 && index - 1 < _messages.messages.length) {
                final prevMsg = _messages.messages[index - 1];
                final prevDate = prevMsg.createdAt ?? DateTime.now();
                prevDay = DateTime(prevDate.year, prevDate.month, prevDate.day);
              }

              final showDateHeader = index == 0 ||
                  prevDay == null ||
                  !currentDay.isAtSameMomentAs(prevDay);

              return Column(
                children: [
                  if (showDateHeader)
                    Container(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      alignment: Alignment.center,
                      child: Text(
                        '${msgDate.day}/${msgDate.month}/${msgDate.year}',
                        style: const TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                    ),
                  GestureDetector(
                    onLongPress: () => _showMessageMenu(context, message),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 4,
                      ),
                      child: SizeTransition(
                        sizeFactor: animation,
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
            fileMessageBuilder: _fileMessageBuilder,
            imageMessageBuilder: _imageMessageBuilder,
            textMessageBuilder: _textMessageBuilder,
            composerBuilder: (context) {
              return PrysmChatComposerOverlay(
                onSendText: _handleSendText,
                onSendImage: _handleSendImage,
                onSendFile: _handleSendFile,
                onSendVoice: _handleSendVoice,
              );
            },
          ),
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
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
      ),
      body: Center(
        child: InteractiveViewer(
          child: Image.memory(imageBytes, fit: BoxFit.contain),
        ),
      ),
    );
  }
}
