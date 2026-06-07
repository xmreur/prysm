import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_chat_core/flutter_chat_core.dart';
import 'package:flutter_chat_ui/flutter_chat_ui.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:prysm/util/download_location.dart';
import 'package:prysm/constants/group_constants.dart';
import 'package:prysm/database/messages.dart';
import 'package:prysm/models/contact.dart';
import 'package:prysm/models/group.dart';
import 'package:prysm/screens/group_settings_screen.dart';
import 'package:prysm/screens/message_composer.dart';
import 'package:prysm/screens/widgets/contact_avatar.dart';
import 'package:prysm/services/group_chat_service.dart';
import 'package:prysm/services/group_service.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/util/group_crypto.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

class GroupChatScreen extends StatefulWidget {
  final String userId;
  final Group group;
  final List<Contact> contacts;
  final KeyManager keyManager;
  final VoidCallback reloadConversations;
  final VoidCallback? onCloseChat;

  const GroupChatScreen({
    required this.userId,
    required this.group,
    required this.contacts,
    required this.keyManager,
    required this.reloadConversations,
    this.onCloseChat,
    super.key,
  });

  @override
  State<GroupChatScreen> createState() => _GroupChatScreenState();
}

class _GroupChatScreenState extends State<GroupChatScreen> {
  late GroupService _groupService;
  late GroupChatService _chatService;
  late User _user;

  var _messages = InMemoryChatController();
  final Map<String, String> _senderNames = {};
  int _memberCount = 0;

  bool _loading = false;
  bool _hasMore = true;
  int? _oldestTimestamp;
  String? _oldestMessageId;

  StreamSubscription? _newMessagesSub;
  StreamSubscription? _statusSub;

  Message? _replyToMessage;
  final Set<String> selectedMessageIds = {};

  static final _urlRegex = RegExp(
    r'https?://[^\s<>\[\]{}|\\^`]+',
    caseSensitive: false,
  );

  @override
  void initState() {
    super.initState();
    _bootstrapForGroup();
  }

  void _bootstrapForGroup() {
    _user = User(id: widget.userId);
    _groupService = GroupService(userId: widget.userId, keyManager: widget.keyManager);
    _chatService = GroupChatService(
      userId: widget.userId,
      groupId: widget.group.id,
      keyManager: widget.keyManager,
      groupService: _groupService,
    );
    _init();
  }

  @override
  void didUpdateWidget(GroupChatScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.group.id != widget.group.id) {
      _teardown();
      _messages = InMemoryChatController();
      _senderNames.clear();
      _memberCount = 0;
      _loading = false;
      _hasMore = true;
      _oldestTimestamp = null;
      _oldestMessageId = null;
      _bootstrapForGroup();
    }
  }

  void _teardown() {
    _newMessagesSub?.cancel();
    _statusSub?.cancel();
    _chatService.dispose();
  }

  Future<void> _init() async {
    final members = await _groupService.getMembers(widget.group.id);
    _memberCount = members.length;
    await _resolveSenderNames(members.map((m) => m.memberId).toList());

    final ok = await _chatService.initialize();
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Waiting for group key…')),
      );
      _waitForGroupKey();
    }

    _newMessagesSub = _chatService.onNewMessages.listen(_handleNewMessages);
    _statusSub = _chatService.onMessageStatus.listen(_handleStatusUpdate);

    await _loadMoreMessages();
    _chatService.startPolling();
    _chatService.startSendQueue();

    if (mounted) setState(() {});
  }

  Widget _buildReplyPreview() {
    if (_replyToMessage == null) return const SizedBox.shrink();
    String previewText;
    if (_replyToMessage is TextMessage) {
      previewText = (_replyToMessage as TextMessage).text;
    } else if (_replyToMessage is ImageMessage) {
      previewText = '📷 Image';
    } else if (_replyToMessage is FileMessage) {
      previewText = '📎 File: ${(_replyToMessage as FileMessage).name}';
    } else {
      previewText = 'Message';
    }
    return Container(
      color: Theme.of(context).brightness == Brightness.dark
          ? Theme.of(context).colorScheme.secondary
          : Theme.of(context).colorScheme.primary,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              previewText,
              style: TextStyle(
                color: Theme.of(context).brightness == Brightness.dark
                    ? Colors.black
                    : Colors.white,
                fontStyle: FontStyle.italic,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close),
            color: Theme.of(context).brightness == Brightness.dark
                ? Colors.black
                : Colors.white,
            onPressed: () => setState(() => _replyToMessage = null),
          ),
        ],
      ),
    );
  }

  Widget _buildLinkedText(String text, Color textColor, double fontSize) {
    final matches = _urlRegex.allMatches(text).toList();
    if (matches.isEmpty) {
      return Text(text, style: TextStyle(color: textColor, fontSize: fontSize));
    }

    final spans = <InlineSpan>[];
    var lastEnd = 0;
    for (final match in matches) {
      if (match.start > lastEnd) {
        spans.add(TextSpan(
          text: text.substring(lastEnd, match.start),
          style: TextStyle(color: textColor, fontSize: fontSize),
        ));
      }
      final url = match.group(0)!;
      spans.add(WidgetSpan(
        alignment: PlaceholderAlignment.baseline,
        baseline: TextBaseline.alphabetic,
        child: GestureDetector(
          onTap: () => _openUrl(url),
          onLongPress: () {
            Clipboard.setData(ClipboardData(text: url));
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Link copied'), duration: Duration(seconds: 1)),
            );
          },
          child: Text(
            url,
            style: TextStyle(
              color: textColor,
              fontSize: fontSize,
              decoration: TextDecoration.underline,
              decorationColor: textColor.withAlpha(180),
            ),
          ),
        ),
      ));
      lastEnd = match.end;
    }
    if (lastEnd < text.length) {
      spans.add(TextSpan(
        text: text.substring(lastEnd),
        style: TextStyle(color: textColor, fontSize: fontSize),
      ));
    }
    return RichText(text: TextSpan(children: spans));
  }

  Future<void> _openUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri != null && await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  void _showMessageMenu(Message message) {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.reply),
              title: const Text('Reply'),
              onTap: () {
                Navigator.pop(ctx);
                setState(() => _replyToMessage = message);
              },
            ),
            ListTile(
              leading: const Icon(Icons.select_all),
              title: const Text('Select'),
              onTap: () {
                Navigator.pop(ctx);
                setState(() => selectedMessageIds.add(message.id));
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Delete'),
              onTap: () async {
                Navigator.pop(ctx);
                final storageId = MessagesDb.scopedId(
                  wireId: message.id,
                  groupId: widget.group.id,
                );
                await MessagesDb.deleteMessageById(storageId);
                if (mounted) {
                  setState(() {
                    _messages.removeMessage(message);
                  });
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _deleteSelectedMessages() async {
    for (final id in selectedMessageIds) {
      final storageId = MessagesDb.scopedId(wireId: id, groupId: widget.group.id);
      await MessagesDb.deleteMessageById(storageId);
    }
    if (!mounted) return;
    setState(() {
      for (final id in List<String>.from(selectedMessageIds)) {
        try {
          final msg = _messages.messages.firstWhere((m) => m.id == id);
          _messages.removeMessage(msg);
        } catch (_) {}
      }
      selectedMessageIds.clear();
    });
  }

  Widget _replyPreviewWidget(Message message, bool isSentByMe) {
    final replyId = message.replyToMessageId;
    if (replyId == null) return const SizedBox.shrink();
    Message? repliedMessage;
    for (final m in _messages.messages) {
      if (m.id == replyId) {
        repliedMessage = m;
        break;
      }
    }
    if (repliedMessage == null) return const SizedBox.shrink();

    String previewText;
    if (repliedMessage is TextMessage) {
      previewText = repliedMessage.text;
    } else if (repliedMessage is ImageMessage) {
      previewText = '📷 Image';
    } else if (repliedMessage is FileMessage) {
      previewText = '📎 File: ${repliedMessage.name}';
    } else {
      previewText = 'Message';
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        previewText,
        style: TextStyle(
          fontStyle: FontStyle.italic,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          fontSize: 12,
        ),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        textAlign: isSentByMe ? TextAlign.right : TextAlign.left,
      ),
    );
  }

  Future<void> _waitForGroupKey() async {
    for (var i = 0; i < 24; i++) {
      await Future.delayed(const Duration(seconds: 5));
      if (!mounted) return;
      final ready = await _chatService.initialize();
      if (ready) {
        await _loadMoreMessages();
        if (mounted) setState(() {});
        return;
      }
    }
  }

  Future<void> _resolveSenderNames(List<String> memberIds) async {
    for (final id in memberIds) {
      if (id == widget.userId) {
        _senderNames[id] = 'You';
        continue;
      }
      final contact = widget.contacts.cast<Contact?>().firstWhere(
            (c) => c!.id == id,
            orElse: () => null,
          );
      if (contact != null) {
        _senderNames[id] = contact.displayName;
      } else {
        final user = await DBHelper.getUserById(id);
        _senderNames[id] = user?['customName'] as String? ??
            user?['name'] as String? ??
            id.substring(0, 6);
      }
    }
  }

  void _handleNewMessages(List<Map<String, dynamic>> raw) async {
    if (!mounted) return;
    final decrypted = await _decryptBatch(raw);
    setState(() {
      final existing = _messages.messages.map((m) => m.id).toSet();
      for (final msg in decrypted) {
        if (!existing.contains(msg.id)) {
          _messages.insertMessage(msg, index: _messages.messages.length);
        }
      }
    });
  }

  void _handleStatusUpdate(GroupMessageStatusUpdate update) {
    if (!mounted) return;
    final idx = _messages.messages.indexWhere((m) => m.id == update.messageId);
    if (idx == -1) return;
    final msg = _messages.messages[idx];
    setState(() {
      if (msg is TextMessage) {
        _messages.updateMessage(
          msg,
          msg.copyWith(
            seenAt: update.status == 'read' ? DateTime.now() : msg.seenAt,
            metadata: {
              ...?msg.metadata,
              'failed': update.status == 'failed',
            },
          ),
        );
      } else if (msg is ImageMessage) {
        _messages.updateMessage(
          msg,
          msg.copyWith(
            seenAt: update.status == 'read' ? DateTime.now() : msg.seenAt,
            metadata: {
              ...?msg.metadata,
              'failed': update.status == 'failed',
            },
          ),
        );
      } else if (msg is FileMessage) {
        _messages.updateMessage(
          msg,
          msg.copyWith(
            seenAt: update.status == 'read' ? DateTime.now() : msg.seenAt,
            metadata: {
              ...?msg.metadata,
              'failed': update.status == 'failed',
            },
          ),
        );
      }
    });
  }

  void _resendMessage(Message message) {
    _chatService.resendMessage(message.id);
    final idx = _messages.messages.indexWhere((m) => m.id == message.id);
    if (idx == -1) return;
    final msg = _messages.messages[idx];
    setState(() {
      if (msg is TextMessage) {
        _messages.updateMessage(
          msg,
          msg.copyWith(metadata: {...?msg.metadata, 'failed': false}),
        );
      } else if (msg is ImageMessage) {
        _messages.updateMessage(
          msg,
          msg.copyWith(metadata: {...?msg.metadata, 'failed': false}),
        );
      } else if (msg is FileMessage) {
        _messages.updateMessage(
          msg,
          msg.copyWith(metadata: {...?msg.metadata, 'failed': false}),
        );
      }
    });
  }

  Future<Uint8List> _decryptGroupFileBytes(Map<String, dynamic> msg) async {
    final groupKey = await _groupService.getDecryptedGroupKey(widget.group.id);
    if (groupKey == null) throw Exception('No group key');
    return GroupCrypto.decryptGroupFile(groupKey, msg['message'] as String);
  }

  Future<List<Message>> _decryptBatch(List<Map<String, dynamic>> raw) async {
    final groupKey = await _groupService.getDecryptedGroupKey(widget.group.id);
    if (groupKey == null) return [];

    final List<Message> result = [];
    for (final msg in raw) {
      try {
        final type = msg['type'] as String;
        final authorId = msg['senderId'] as String;
        final createdAt = DateTime.fromMillisecondsSinceEpoch(msg['timestamp'] as int);
        final id = MessagesDb.wireIdFromStorage(msg['id'] as String);
        final replyTo = msg['replyTo'] as String?;
        final seenAt = msg['readAt'] != null
            ? DateTime.fromMillisecondsSinceEpoch(msg['readAt'] as int)
            : null;

        if (type == groupTextType) {
          final text = GroupCrypto.decryptText(groupKey, msg['message'] as String);
          result.add(TextMessage(
            authorId: authorId,
            createdAt: createdAt,
            id: id,
            text: text,
            replyToMessageId: replyTo,
            seenAt: seenAt,
          ));
        } else if (type == groupImageType) {
          final isViewOnce = (msg['viewOnce'] ?? 0) == 1;
          final isViewed = (msg['viewed'] ?? 0) == 1;
          if (isViewOnce && isViewed) {
            result.add(ImageMessage(
              id: id,
              authorId: authorId,
              createdAt: createdAt,
              replyToMessageId: replyTo,
              size: 0,
              seenAt: seenAt,
              source: '',
              metadata: const {'viewOnce': true, 'viewed': true},
            ));
          } else if (isViewOnce) {
            result.add(ImageMessage(
              id: id,
              authorId: authorId,
              createdAt: createdAt,
              replyToMessageId: replyTo,
              size: msg['fileSize'] as int? ?? 0,
              seenAt: seenAt,
              source: '',
              metadata: const {'viewOnce': true, 'viewed': false},
            ));
          } else {
            final bytes = GroupCrypto.decryptGroupFile(groupKey, msg['message'] as String);
            result.add(ImageMessage(
              id: id,
              authorId: authorId,
              createdAt: createdAt,
              replyToMessageId: replyTo,
              size: bytes.length,
              seenAt: seenAt,
              source: 'data:image/png;base64,${base64Encode(bytes)}',
            ));
          }
        } else if (type == groupFileType || type == groupAudioType) {
          final bytes = GroupCrypto.decryptGroupFile(groupKey, msg['message'] as String);
          if (type == groupAudioType) {
            final cacheDir = await getTemporaryDirectory();
            final cachePath = '${cacheDir.path}/group_voice_$id.wav';
            await File(cachePath).writeAsBytes(bytes);
            result.add(FileMessage(
              id: id,
              authorId: authorId,
              createdAt: createdAt,
              replyToMessageId: replyTo,
              name: msg['fileName'] as String? ?? 'voice_message.wav',
              size: bytes.length,
              seenAt: seenAt,
              source: 'audio:0:$cachePath',
            ));
          } else {
            final fileName = msg['fileName'] as String? ?? 'file';
            result.add(FileMessage(
              id: id,
              authorId: authorId,
              createdAt: createdAt,
              replyToMessageId: replyTo,
              name: fileName,
              size: bytes.length,
              seenAt: seenAt,
              source: base64Encode(bytes),
            ));
          }
        }
      } catch (_) {
        result.add(TextMessage(
          authorId: msg['senderId'] as String,
          createdAt: DateTime.fromMillisecondsSinceEpoch(msg['timestamp'] as int),
          id: MessagesDb.wireIdFromStorage(msg['id'] as String),
          text: 'Unable to decrypt message',
        ));
      }
    }
    return result;
  }

  Future<void> _loadMoreMessages() async {
    if (_loading || !_hasMore) return;
    _loading = true;

    final batch = await MessagesDb.getMessagesForGroupBatch(
      widget.group.id,
      limit: 20,
      beforeTimestamp: _oldestTimestamp,
      beforeId: _oldestMessageId,
    );

    if (!mounted) return;

    if (batch.length < 20) _hasMore = false;
    if (batch.isEmpty) {
      _loading = false;
      return;
    }

    final sorted = List<Map<String, dynamic>>.from(batch)
      ..sort((a, b) => (a['timestamp'] as int).compareTo(b['timestamp'] as int));

    if (sorted.isNotEmpty) {
      final newestTs = sorted
          .map((m) => m['timestamp'] as int)
          .reduce((a, b) => a > b ? a : b);
      _chatService.seedNewestTimestamp(newestTs);
    }

    final decrypted = await _decryptBatch(sorted);

    setState(() {
      _messages.insertAllMessages(decrypted, index: 0);
      _oldestTimestamp = batch.last['timestamp'] as int;
      _oldestMessageId = batch.last['id'] as String;
      _loading = false;
    });
  }

  void _handleSendText(String text) async {
    final messageId = const Uuid().v4();
    final replyToId = _replyToMessage?.id;
    setState(() {
      _messages.insertMessage(
        TextMessage(
          authorId: _user.id,
          createdAt: DateTime.now(),
          id: messageId,
          text: text,
          sentAt: DateTime.now(),
          replyToMessageId: replyToId,
        ),
        index: _messages.messages.length,
      );
      _replyToMessage = null;
    });
    final sentId = await _chatService.sendTextMessage(
      text,
      messageId: messageId,
      replyToId: replyToId,
    );
    if (sentId == null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not send message — group key unavailable')),
      );
    }
    widget.reloadConversations();
  }

  void _sendFile(Uint8List bytes, String fileName, String type, {bool viewOnce = false}) async {
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
            sentAt: DateTime.now(),
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
            source: 'data:image/png;base64,${base64Encode(bytes)}',
            sentAt: DateTime.now(),
            metadata: viewOnce ? const {'viewOnce': true, 'viewed': false} : null,
          ),
          index: _messages.messages.length,
        );
      }
    });

    final sentId = await _chatService.sendFileMessage(
      bytes,
      fileName,
      type,
      messageId: messageId,
      viewOnce: viewOnce,
    );
    if (sentId == null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Message queued. Will send when members are reachable.')),
      );
    }
    widget.reloadConversations();
  }

  Future<void> _handleSendImage() async {
    final picker = ImagePicker();
    final pickedFile = await picker.pickImage(source: ImageSource.gallery);
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
      } catch (_) {}
    }

    if (!mounted) return;

    final viewOnce = await showModalBottomSheet<bool>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.image),
              title: const Text('Send Photo'),
              onTap: () => Navigator.pop(ctx, false),
            ),
            ListTile(
              leading: const Icon(Icons.timer),
              title: const Text('View Once'),
              onTap: () => Navigator.pop(ctx, true),
            ),
          ],
        ),
      ),
    );

    if (viewOnce == null) return;
    _sendFile(bytes, pickedFile.name, 'image', viewOnce: viewOnce);
  }

  Future<void> _handleSendFile() async {
    final result = await FilePicker.platform.pickFiles(withData: true);
    if (result == null || result.files.isEmpty) return;
    final file = result.files.first;
    if (file.bytes == null) return;
    _sendFile(file.bytes!, file.name, 'file');
  }

  Future<void> _handleSendVoice(Uint8List bytes, int durationMs) async {
    final messageId = const Uuid().v4();
    final cacheDir = await getTemporaryDirectory();
    final cachePath = '${cacheDir.path}/group_voice_cache_$messageId.wav';
    await File(cachePath).writeAsBytes(bytes);

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
          sentAt: DateTime.now(),
        ),
        index: _messages.messages.length,
      );
    });

    await _chatService.sendFileMessage(bytes, 'voice_message.wav', 'audio', messageId: messageId);
    widget.reloadConversations();
  }

  Widget _senderLabel(String authorId, bool isSentByMe) {
    if (isSentByMe) return const SizedBox.shrink();
    final name = _senderNames[authorId] ?? authorId;
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 2),
      child: Text(
        name,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }

  void _openSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => GroupSettingsScreen(
          group: widget.group,
          userId: widget.userId,
          contacts: widget.contacts,
          keyManager: widget.keyManager,
          onChanged: () async {
            final members = await _groupService.getMembers(widget.group.id);
            if (mounted) {
              setState(() => _memberCount = members.length);
              await _resolveSenderNames(members.map((m) => m.memberId).toList());
            }
            widget.reloadConversations();
          },
          onLeftOrDeleted: () {
            widget.onCloseChat?.call();
            widget.reloadConversations();
          },
        ),
      ),
    );
  }

  @override
  void dispose() {
    _teardown();
    super.dispose();
  }

  Widget _buildStatusWidget(Message message, bool isSentByMe, Color tickColor) {
    if (!isSentByMe) return const SizedBox.shrink();

    final isFailed = message.metadata?['failed'] == true;
    if (isFailed) {
      return GestureDetector(
        onTap: () => _resendMessage(message),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.warning_amber_rounded, size: 14, color: Colors.red[400]),
            const SizedBox(width: 2),
            Text('Tap to retry', style: TextStyle(fontSize: 9, color: Colors.red[400])),
          ],
        ),
      );
    }

    if (message.seenAt != null) {
      return Icon(Icons.done_all, size: 14, color: tickColor);
    } else if (message.sentAt != null) {
      return Icon(Icons.done, size: 14, color: tickColor.withAlpha(140));
    }
    return const SizedBox.shrink();
  }

  Widget _groupTextMessageBuilder(
    BuildContext context,
    TextMessage message,
    int index, {
    required bool isSentByMe,
    MessageGroupStatus? groupStatus,
  }) {
    final msgDate = DateTime.fromMillisecondsSinceEpoch(
      message.createdAt!.millisecondsSinceEpoch,
    );
    final timeString =
        '${msgDate.hour.toString().padLeft(2, '0')}:${msgDate.minute.toString().padLeft(2, '0')}';

    final tickColor = isSentByMe
        ? Theme.of(context).colorScheme.onPrimary.withAlpha(200)
        : Theme.of(context).colorScheme.onSecondary.withAlpha(200);

    return Column(
      crossAxisAlignment:
          isSentByMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        _senderLabel(message.authorId, isSentByMe),
        IntrinsicWidth(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: isSentByMe
                  ? Theme.of(context).colorScheme.primary.withAlpha(225)
                  : Theme.of(context).colorScheme.secondary.withAlpha(225),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                _replyPreviewWidget(message, isSentByMe),
                _buildLinkedText(
                  message.text,
                  isSentByMe
                      ? Theme.of(context).colorScheme.onPrimary
                      : Theme.of(context).colorScheme.onSecondary,
                  16,
                ),
                const SizedBox(height: 4),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      timeString,
                      style: TextStyle(
                        fontSize: 10,
                        color: tickColor,
                      ),
                    ),
                    if (isSentByMe) ...[
                      const SizedBox(width: 4),
                      _buildStatusWidget(message, isSentByMe, tickColor),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _groupImageMessageBuilder(
    BuildContext context,
    ImageMessage message,
    int index, {
    required bool isSentByMe,
    MessageGroupStatus? groupStatus,
  }) {
    final isViewOnce = message.metadata?['viewOnce'] == true;
    final isViewed = message.metadata?['viewed'] == true;
    final msgDate = DateTime.fromMillisecondsSinceEpoch(
      message.createdAt!.millisecondsSinceEpoch,
    );
    final timeString =
        '${msgDate.hour.toString().padLeft(2, '0')}:${msgDate.minute.toString().padLeft(2, '0')}';
    final tickWidget = isSentByMe
        ? _buildStatusWidget(
            message,
            isSentByMe,
            Colors.white.withAlpha(220),
          )
        : const SizedBox.shrink();

    if (isViewOnce && isViewed) {
      return Column(
        crossAxisAlignment:
            isSentByMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          _senderLabel(message.authorId, isSentByMe),
          Container(
            width: 200,
            height: 60,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Center(
              child: Text('Opened', style: TextStyle(fontStyle: FontStyle.italic)),
            ),
          ),
        ],
      );
    }

    if (isViewOnce && !isViewed) {
      return Column(
        crossAxisAlignment:
            isSentByMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          _senderLabel(message.authorId, isSentByMe),
          GestureDetector(
            onTap: isSentByMe
                ? null
                : () async {
                    final rows = await MessagesDb.getMessageById(
                      message.id,
                      groupId: widget.group.id,
                    );
                    if (rows.isEmpty) return;
                    try {
                      final bytes = await _decryptGroupFileBytes(rows.first);
                      if (!context.mounted) return;
                      await Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => _GroupViewOnceScreen(imageBytes: bytes),
                        ),
                      );
                      await MessagesDb.markViewOnceViewed(
                        message.id,
                        groupId: widget.group.id,
                      );
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
                      debugPrint('View-once failed: $e');
                    }
                  },
            child: Container(
              width: 200,
              height: 200,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: Theme.of(context).colorScheme.primary.withAlpha(100),
                  width: 2,
                ),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.visibility,
                    size: 40,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    isSentByMe ? 'View Once Photo' : 'Tap to View',
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
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(timeString, style: TextStyle(fontSize: 10, color: Colors.grey[600])),
              if (isSentByMe) ...[const SizedBox(width: 4), tickWidget],
            ],
          ),
        ],
      );
    }

    Uint8List? imageBytes;
    final src = message.source;
    if (src.startsWith('data:image') && src.contains(',')) {
      try {
        imageBytes = base64Decode(src.split(',').last);
      } catch (_) {}
    }

    return Column(
      crossAxisAlignment:
          isSentByMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        _senderLabel(message.authorId, isSentByMe),
        if (imageBytes != null)
          GestureDetector(
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => Scaffold(
                    backgroundColor: Theme.of(context).brightness == Brightness.dark
                        ? Colors.black
                        : Colors.white,
                    appBar: AppBar(
                      backgroundColor: Colors.transparent,
                      elevation: 0,
                    ),
                    body: Center(
                      child: InteractiveViewer(child: Image.memory(imageBytes!)),
                    ),
                  ),
                ),
              );
            },
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.memory(
                imageBytes,
                width: max(200, (message.width ?? 20) / 4),
                height: max(200, (message.height ?? 20) / 4),
                fit: BoxFit.cover,
              ),
            ),
          )
        else
          const SizedBox(
            width: 200,
            height: 120,
            child: Icon(Icons.broken_image),
          ),
        const SizedBox(height: 4),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(timeString, style: TextStyle(fontSize: 10, color: Colors.grey[600])),
            if (isSentByMe) ...[const SizedBox(width: 4), tickWidget],
          ],
        ),
      ],
    );
  }

  Widget _groupFileMessageBuilder(
    BuildContext context,
    FileMessage message,
    int index, {
    required bool isSentByMe,
    MessageGroupStatus? groupStatus,
  }) {
    if (message.name.contains('voice_message') || message.source.startsWith('audio:')) {
      final msgDate = DateTime.fromMillisecondsSinceEpoch(
        message.createdAt!.millisecondsSinceEpoch,
      );
      final timeString =
          '${msgDate.hour.toString().padLeft(2, '0')}:${msgDate.minute.toString().padLeft(2, '0')}';
      final tickColor = isSentByMe
          ? Theme.of(context).colorScheme.onPrimary.withAlpha(200)
          : Theme.of(context).colorScheme.onSecondary.withAlpha(200);
      return Column(
        crossAxisAlignment:
            isSentByMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          _senderLabel(message.authorId, isSentByMe),
          _GroupVoiceMessageBubble(
            message: message,
            isSentByMe: isSentByMe,
            timeString: timeString,
            tickWidget: _buildStatusWidget(message, isSentByMe, tickColor),
          ),
        ],
      );
    }

    final msgDate = DateTime.fromMillisecondsSinceEpoch(
      message.createdAt!.millisecondsSinceEpoch,
    );
    final timeString =
        '${msgDate.hour.toString().padLeft(2, '0')}:${msgDate.minute.toString().padLeft(2, '0')}';
    final tickColor = isSentByMe
        ? Theme.of(context).colorScheme.onPrimary.withAlpha(200)
        : Theme.of(context).colorScheme.onSecondary.withAlpha(200);

    final maxWidth = MediaQuery.of(context).size.width * 0.55;
    final isLoading = ValueNotifier(false);

    Future<void> handleDownload() async {
      if (isLoading.value) return;
      isLoading.value = true;
      try {
        if (message.source.isEmpty) return;
        final bytes = base64Decode(message.source);

        final file = await DownloadLocation.saveBytes(bytes, message.name);
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Saved ${file.path.split('/').last}')),
        );
      } catch (e) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error downloading file: $e')),
        );
      } finally {
        isLoading.value = false;
      }
    }

    String fileSizeString = '';
    if (message.size != null) {
      final sizeInKB = message.size! / 1024;
      fileSizeString = sizeInKB < 1024
          ? '${sizeInKB.toStringAsFixed(1)} KB'
          : '${(sizeInKB / 1024).toStringAsFixed(1)} MB';
    }

    return Column(
      crossAxisAlignment:
          isSentByMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        _senderLabel(message.authorId, isSentByMe),
        GestureDetector(
          onTap: handleDownload,
          child: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primary.withAlpha(225),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.insert_drive_file,
                    color: Theme.of(context).colorScheme.onPrimary),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    message.name,
                    style: TextStyle(color: Theme.of(context).colorScheme.onPrimary),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 4),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(timeString, style: TextStyle(fontSize: 10, color: Colors.grey[600])),
            if (isSentByMe) ...[
              const SizedBox(width: 4),
              _buildStatusWidget(message, isSentByMe, tickColor),
            ],
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 70,
        leading: IconButton(
          icon: const Icon(Icons.chevron_left, size: 30),
          onPressed: () {
            if (widget.onCloseChat != null) {
              widget.onCloseChat!();
            } else {
              Navigator.of(context).maybePop();
            }
          },
        ),
        title: Row(
          children: [
            ContactAvatar(
              name: widget.group.name,
              radius: 20,
              avatarBase64: widget.group.avatarBase64,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.group.name,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '$_memberCount members',
                    style: TextStyle(
                      color: Theme.of(context).hintColor,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          if (selectedMessageIds.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: _deleteSelectedMessages,
            ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            onPressed: _openSettings,
          ),
        ],
        elevation: 2,
        shadowColor: Colors.black.withValues(alpha: 0.1),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Chat(
                currentUserId: _user.id,
                resolveUser: (id) async => User(id: id),
                chatController: _messages,
                theme: ChatTheme.fromThemeData(Theme.of(context)),
                onMessageSend: _handleSendText,
                builders: Builders(
                  chatAnimatedListBuilder: (context, itemBuilder) {
                    return ChatAnimatedList(
                      itemBuilder: itemBuilder,
                      onEndReached: () async {
                        await _loadMoreMessages();
                      },
                    );
                  },
                  chatMessageBuilder: (
                    BuildContext context,
                    Message message,
                    int index,
                    Animation<double> animation,
                    Widget child, {
                    bool? isRemoved,
                    required bool isSentByMe,
                    MessageGroupStatus? groupStatus,
                  }) {
                    final msgDate = DateTime.fromMillisecondsSinceEpoch(
                      message.createdAt!.millisecondsSinceEpoch,
                    );
                    final currentDay = DateTime(
                      msgDate.year,
                      msgDate.month,
                      msgDate.day,
                    );

                    DateTime? prevDay;
                    if (index > 0 && index - 1 < _messages.messages.length) {
                      final prevMsg = _messages.messages[index - 1];
                      final prevDate = DateTime.fromMillisecondsSinceEpoch(
                        prevMsg.createdAt!.millisecondsSinceEpoch,
                      );
                      prevDay = DateTime(
                        prevDate.year,
                        prevDate.month,
                        prevDate.day,
                      );
                    }

                    final showDateHeader = index == 0 ||
                        prevDay == null ||
                        !currentDay.isAtSameMomentAs(prevDay);

                    final isSelected = selectedMessageIds.contains(message.id);

                    return Column(
                      children: [
                        if (showDateHeader)
                          Container(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            alignment: Alignment.center,
                            child: Text(
                              '${msgDate.day}/${msgDate.month}/${msgDate.year}',
                              style: const TextStyle(
                                fontSize: 12,
                                color: Colors.grey,
                              ),
                            ),
                          ),
                        GestureDetector(
                          onLongPress: () => _showMessageMenu(message),
                          onTap: selectedMessageIds.isNotEmpty
                              ? () {
                                  setState(() {
                                    if (isSelected) {
                                      selectedMessageIds.remove(message.id);
                                    } else {
                                      selectedMessageIds.add(message.id);
                                    }
                                  });
                                }
                              : null,
                          child: SizeTransition(
                            sizeFactor: animation,
                            child: Container(
                              decoration: isSelected
                                  ? BoxDecoration(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .primary
                                          .withAlpha(40),
                                    )
                                  : null,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 4,
                                ),
                                child: Row(
                                  mainAxisAlignment: isSentByMe
                                      ? MainAxisAlignment.end
                                      : MainAxisAlignment.start,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Flexible(child: child),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                  textMessageBuilder: _groupTextMessageBuilder,
                  imageMessageBuilder: _groupImageMessageBuilder,
                  fileMessageBuilder: _groupFileMessageBuilder,
                  composerBuilder: (context) {
                    return Padding(padding: EdgeInsetsGeometry.infinity);
                  },
                ),
              ),
            ),
            _buildReplyPreview(),
            MessageComposer(
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

class _GroupVoiceMessageBubble extends StatefulWidget {
  final FileMessage message;
  final bool isSentByMe;
  final String timeString;
  final Widget tickWidget;

  const _GroupVoiceMessageBubble({
    required this.message,
    required this.isSentByMe,
    required this.timeString,
    required this.tickWidget,
  });

  @override
  State<_GroupVoiceMessageBubble> createState() => _GroupVoiceMessageBubbleState();
}

class _GroupVoiceMessageBubbleState extends State<_GroupVoiceMessageBubble> {
  AudioPlayer? _player;
  bool _isPlaying = false;

  @override
  void dispose() {
    _player?.dispose();
    super.dispose();
  }

  Future<String?> _audioPath() async {
    if (!widget.message.source.startsWith('audio:')) return null;
    final parts = widget.message.source.split(':');
    if (parts.length < 3) return null;
    return parts.sublist(2).join(':');
  }

  Future<void> _togglePlay() async {
    final path = await _audioPath();
    if (path == null || !await File(path).exists()) return;

    _player ??= AudioPlayer();
    if (_isPlaying) {
      await _player!.stop();
      if (mounted) setState(() => _isPlaying = false);
      return;
    }

    await _player!.play(DeviceFileSource(path));
    _player!.onPlayerComplete.listen((_) {
      if (mounted) setState(() => _isPlaying = false);
    });
    if (mounted) setState(() => _isPlaying = true);
  }

  @override
  Widget build(BuildContext context) {
    final bubbleColor = widget.isSentByMe
        ? Theme.of(context).colorScheme.primary.withAlpha(225)
        : Theme.of(context).colorScheme.secondary.withAlpha(225);
    final iconColor = widget.isSentByMe
        ? Theme.of(context).colorScheme.onPrimary
        : Theme.of(context).colorScheme.onSecondary;

    return Column(
      crossAxisAlignment:
          widget.isSentByMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        GestureDetector(
          onTap: _togglePlay,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: bubbleColor,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _isPlaying ? Icons.pause_circle_filled : Icons.play_circle_filled,
                  color: iconColor,
                ),
                const SizedBox(width: 8),
                Text('Voice message', style: TextStyle(color: iconColor)),
              ],
            ),
          ),
        ),
        const SizedBox(height: 4),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(widget.timeString, style: TextStyle(fontSize: 10, color: Colors.grey[600])),
            if (widget.isSentByMe) ...[
              const SizedBox(width: 4),
              widget.tickWidget,
            ],
          ],
        ),
      ],
    );
  }
}

class _GroupViewOnceScreen extends StatelessWidget {
  final Uint8List imageBytes;

  const _GroupViewOnceScreen({required this.imageBytes});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black),
      body: Center(
        child: InteractiveViewer(
          child: Image.memory(imageBytes),
        ),
      ),
    );
  }
}
