import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_chat_core/flutter_chat_core.dart';
import 'package:flutter_chat_ui/flutter_chat_ui.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:prysm/constants/group_constants.dart';
import 'package:prysm/database/message_reactions.dart';
import 'package:prysm/database/messages.dart';
import 'package:prysm/models/contact.dart';
import 'package:prysm/models/group.dart';
import 'package:prysm/screens/group_settings_screen.dart';
import 'package:prysm/screens/widgets/prysm_chat_composer_overlay.dart';
import 'package:prysm/util/chat_scroll.dart';
import 'package:prysm/screens/widgets/contact_avatar.dart';
import 'package:prysm/screens/widgets/message_reaction_bar.dart';
import 'package:prysm/screens/widgets/message_reaction_picker.dart';
import 'package:prysm/screens/widgets/file_attachment_bubble.dart';
import 'package:prysm/screens/widgets/linked_message_text.dart';
import 'package:prysm/screens/widgets/voice_message_bubble.dart';
import 'package:prysm/screens/widgets/image_message_bubble.dart';
import 'package:prysm/screens/widgets/image_send_preview_screen.dart';
import 'package:prysm/constants/media_constants.dart';
import 'package:prysm/services/file_attachment_resolver.dart';
import 'package:prysm/services/image_attachment_cache.dart';
import 'package:prysm/screens/widgets/deleted_message_bubble.dart';
import 'package:prysm/services/message_modify_service.dart';
import 'package:prysm/services/reaction_service.dart';
import 'package:prysm/services/read_receipt_service.dart';
import 'package:prysm/services/settings_service.dart';
import 'package:prysm/database/message_read_receipts.dart';
import 'package:prysm/screens/widgets/message_status_icon.dart';
import 'package:prysm/screens/widgets/read_receipt_details_sheet.dart';
import 'package:prysm/util/message_status_mapper.dart';
import 'package:prysm/util/outbound_read_status_refresh.dart';
import 'package:prysm/util/read_receipt_refresh_notifier.dart';
import 'package:prysm/util/message_content_wiper.dart';
import 'package:prysm/util/message_modify_policy.dart';
import 'package:prysm/util/message_modify_refresh_notifier.dart';
import 'package:prysm/util/reaction_refresh_notifier.dart';
import 'package:prysm/util/waveform_extractor.dart';
import 'package:prysm/services/group_chat_service.dart';
import 'package:prysm/services/group_service.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/util/group_crypto.dart';
import 'package:prysm/util/group_membership_notifier.dart';
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
  late ReactionService _reactionService;
  late ReadReceiptService _readReceiptService;
  late MessageModifyService _modifyService;
  late User _user;
  final _settings = SettingsService();

  var _messages = InMemoryChatController();
  final ScrollController _listScrollController = ScrollController();
  bool _stickToBottom = true;
  final Map<String, String> _senderNames = {};
  int _memberCount = 0;

  bool _loading = false;
  bool _hasMore = true;
  int? _oldestTimestamp;
  String? _oldestMessageId;
  int? _joinedAt;

  StreamSubscription? _newMessagesSub;
  StreamSubscription? _statusSub;
  StreamSubscription? _reactionSub;
  StreamSubscription? _reactionRefreshSub;
  StreamSubscription? _modifyRefreshSub;
  StreamSubscription? _membershipSub;
  StreamSubscription? _readReceiptRefreshSub;
  Timer? _readReceiptDebounce;
  List<String> _groupMemberIds = [];

  Message? _replyToMessage;
  final Set<String> selectedMessageIds = {};
  final Map<String, double> _dragOffsets = {};

  @override
  void initState() {
    super.initState();
    _listScrollController.addListener(_onListScroll);
    _bootstrapForGroup();
  }

  void _onListScroll() {
    _stickToBottom = isChatScrolledToBottom(_listScrollController);
  }

  void _scheduleScrollToBottomIfNeeded({bool animated = false}) {
    if (!_stickToBottom) return;
    scheduleScrollChatToBottom(
      _messages,
      animated: animated,
      isMounted: () => mounted,
    );
  }

  void _scheduleScrollToBottomAfterSend() {
    _stickToBottom = true;
    scheduleScrollChatToBottom(_messages, isMounted: () => mounted);
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
    _reactionService = ReactionService.group(
      userId: widget.userId,
      keyManager: widget.keyManager,
      groupId: widget.group.id,
      groupService: _groupService,
    );
    _readReceiptService = ReadReceiptService.group(
      userId: widget.userId,
      keyManager: widget.keyManager,
      groupId: widget.group.id,
      groupService: _groupService,
    );
    _modifyService = MessageModifyService.group(
      userId: widget.userId,
      keyManager: widget.keyManager,
      groupId: widget.group.id,
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
    _reactionSub?.cancel();
    _reactionRefreshSub?.cancel();
    _modifyRefreshSub?.cancel();
    _membershipSub?.cancel();
    _readReceiptRefreshSub?.cancel();
    _readReceiptDebounce?.cancel();
    _chatService.unpinMembersForWebSocket();
    _chatService.dispose();
    _reactionService.dispose();
  }

  void _onRemovedFromGroup() {
    if (!mounted) return;
    widget.onCloseChat?.call();
    widget.reloadConversations();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('You are no longer in this group')),
    );
  }

  Future<void> _init() async {
    if (!await _groupService.isMember(widget.group.id)) {
      await _groupService.abandonGroupAfterRemoval(widget.group.id);
      if (mounted) _onRemovedFromGroup();
      return;
    }

    _membershipSub =
        GroupMembershipNotifier.instance.onRemoved.listen((groupId) {
      if (groupId == widget.group.id && mounted) {
        _onRemovedFromGroup();
      }
    });

    _joinedAt = await _groupService.joinedAtForCurrentUser(widget.group.id);
    if (_joinedAt != null) {
      await MessagesDb.deleteGroupMessagesBefore(widget.group.id, _joinedAt!);
    }

    final members = await _groupService.getMembers(widget.group.id);
    _memberCount = members.length;
    _groupMemberIds = members.map((m) => m.memberId).toList();
    await _resolveSenderNames(_groupMemberIds);

    final ok = await _chatService.initialize();
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Waiting for group key…')),
      );
      _waitForGroupKey();
    }

    _newMessagesSub = _chatService.onNewMessages.listen(_handleNewMessages);
    _statusSub = _chatService.onMessageStatus.listen(_handleStatusUpdate);
    _reactionSub = _reactionService.onReactionsChanged.listen(_applyReactionUpdate);
    _reactionRefreshSub =
        ReactionRefreshNotifier.instance.onReactionChanged.listen(_applyReactionUpdate);
    _modifyRefreshSub = MessageModifyRefreshNotifier.instance.onModifyChanged
        .listen(_applyModifyUpdate);
    _readReceiptRefreshSub =
        ReadReceiptRefreshNotifier.instance.onReadReceiptChanged
            .listen(_applyReadReceiptUpdate);

    await _loadMoreMessages();
    await _markInboundAsRead();
    _chatService.startPolling();
    _chatService.startSendQueue();
    _chatService.pinMembersForWebSocket();

    if (mounted && _messages.messages.isNotEmpty) {
      _stickToBottom = true;
      scheduleScrollChatToBottom(_messages, isMounted: () => mounted);
    }

    if (mounted) setState(() {});
  }

  Widget _buildReplyPreview() {
    if (_replyToMessage == null) return const SizedBox.shrink();
    final previewText = isMessageDeleted(_replyToMessage!)
        ? 'Deleted'
        : _replyToMessage is TextMessage
            ? (_replyToMessage as TextMessage).text
            : _replyToMessage is ImageMessage
                ? '📷 Image'
                : _replyToMessage is FileMessage
                    ? '📎 File: ${(_replyToMessage as FileMessage).name}'
                    : 'Message';
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

  Future<void> _openUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri != null && await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  void _showMessageMenu(Message message) {
    if (isMessageDeleted(message)) return;
    final isSentByMe = message.authorId == widget.userId;
    showMessageActionsSheet(
      context: context,
      onReactionSelected: (emoji) => _onReactionSelected(message, emoji),
      actionTiles: [
        if (canEditMessage(message, widget.userId))
          ListTile(
            leading: const Icon(Icons.edit_outlined),
            title: const Text('Edit'),
            onTap: () {
              Navigator.pop(context);
              _editMessage(message);
            },
          ),
        if (isSentByMe)
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('Info'),
            onTap: () {
              Navigator.pop(context);
              _openMessageInfo(message);
            },
          ),
        ListTile(
          leading: const Icon(Icons.reply),
          title: const Text('Reply'),
          onTap: () {
            Navigator.pop(context);
            setState(() => _replyToMessage = message);
          },
        ),
        ListTile(
          leading: const Icon(Icons.select_all),
          title: const Text('Select'),
          onTap: () {
            Navigator.pop(context);
            setState(() => selectedMessageIds.add(message.id));
          },
        ),
        ListTile(
          leading: const Icon(Icons.delete_outline),
          title: Text(isSentByMe ? 'Delete for everyone' : 'Delete'),
          onTap: () async {
            Navigator.pop(context);
            await _deleteMessage(message);
          },
        ),
      ],
    );
  }

  Future<void> _deleteMessage(Message message) async {
    if (canDeleteForEveryone(message, widget.userId)) {
      await _modifyService.deleteMessage(targetMessageId: message.id);
      final storageId = MessagesDb.scopedId(
        wireId: message.id,
        groupId: widget.group.id,
      );
      await MessageReactionsDb.deleteReactionsForMessage(storageId);
      if (mounted) {
        setState(() {
          _messages.updateMessage(message, markMessageDeleted(message));
        });
      }
      return;
    }

    final storageId = MessagesDb.scopedId(
      wireId: message.id,
      groupId: widget.group.id,
    );
    await MessageContentWiper.wipeLocalArtifacts(
      wireId: message.id,
      groupId: widget.group.id,
    );
    await MessagesDb.deleteMessageById(storageId);
    await MessageReactionsDb.deleteReactionsForMessage(storageId);
    if (mounted) {
      setState(() {
        _messages.removeMessage(message);
      });
    }
  }

  Future<void> _editMessage(Message message) async {
    if (message is! TextMessage) return;
    final controller = TextEditingController(text: message.text);
    final newText = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit message'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 4,
          minLines: 1,
          decoration: const InputDecoration(
            hintText: 'Message',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (newText == null || newText.isEmpty || newText == message.text) return;

    final ok = await _modifyService.editTextMessage(
      targetMessageId: message.id,
      newText: newText,
    );
    if (!mounted) return;
    if (ok) {
      setState(() {
        _messages.updateMessage(
          message,
          message.copyWith(
            text: newText,
            metadata: {...?message.metadata, 'edited': true},
          ),
        );
      });
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not edit message')),
      );
    }
  }

  void _applyModifyUpdate(MessageModifyUpdate update) {
    if (!mounted) return;
    try {
      final msg =
          _messages.messages.firstWhere((m) => m.id == update.targetMessageId);
      Message updated;
      if (update.isDelete) {
        updated = markMessageDeleted(msg);
      } else if (msg is TextMessage && update.newText != null) {
        updated = msg.copyWith(
          text: update.newText!,
          metadata: {...?msg.metadata, 'edited': true},
        );
      } else {
        return;
      }
      setState(() {
        _messages.updateMessage(msg, updated);
      });
    } catch (_) {}
  }

  Widget _displayChildForMessage(
    Message message,
    Widget child,
    bool isSentByMe,
  ) {
    if (!isMessageDeleted(message)) return child;
    return DeletedMessageBubble(
      isSentByMe: isSentByMe,
      createdAt: message.createdAt!,
      tickWidget: isSentByMe
          ? _buildStatusWidget(
              message,
              isSentByMe,
              Theme.of(context).colorScheme.onSurface.withAlpha(180),
            )
          : null,
    );
  }

  Future<void> _onReactionSelected(Message message, String emoji) async {
    await _reactionService.toggleReaction(
      targetMessageId: message.id,
      emoji: emoji,
    );
  }

  void _applyReactionUpdate(ReactionUpdate update) {
    if (!mounted) return;
    try {
      final msg =
          _messages.messages.firstWhere((m) => m.id == update.targetMessageId);
      final updated = applyReactionsToMessage(msg, update.reactions);
      setState(() {
        _messages.updateMessage(msg, updated);
      });
    } catch (_) {}
  }

  Widget _reactionBarFor(Message message, bool isSentByMe) {
    final reactions = message.reactions;
    if (reactions == null || reactions.isEmpty) {
      return const SizedBox.shrink();
    }
    return MessageReactionBar(
      reactions: reactions,
      currentUserId: widget.userId,
      isSentByMe: isSentByMe,
      onReactionTap: (emoji) => _onReactionSelected(message, emoji),
    );
  }

  Future<List<Message>> _attachReactions(List<Message> messages) async {
    if (messages.isEmpty) return messages;
    final ids = messages.map((m) => m.id).toList();
    final reactions = await _reactionService.loadReactionsForMessages(ids);
    return messages
        .map((m) => applyReactionsToMessage(m, reactions[m.id]))
        .toList();
  }

  Future<void> _deleteSelectedMessages() async {
    final ids = List<String>.from(selectedMessageIds);
    for (final id in ids) {
      try {
        final msg = _messages.messages.firstWhere((m) => m.id == id);
        await _deleteMessage(msg);
      } catch (_) {}
    }
    if (mounted) {
      setState(() => selectedMessageIds.clear());
    }
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
    if (isMessageDeleted(repliedMessage)) {
      previewText = 'Deleted';
    } else if (repliedMessage is TextMessage) {
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
    _scheduleScrollToBottomIfNeeded();
    await _markInboundAsRead();
  }

  void _handleStatusUpdate(GroupMessageStatusUpdate update) {
    if (!mounted) return;
    final idx = _messages.messages.indexWhere((m) => m.id == update.messageId);
    if (idx == -1) return;
    final msg = _messages.messages[idx];
    setState(() {
      final updated = messageWithDeliveryUpdate(
        msg,
        status: update.status,
        readReceiptsEnabled: _settings.sendReadReceipts,
      );
      _messages.updateMessage(msg, updated);
    });
  }

  Future<void> _markInboundAsRead() async {
    final waterline = await MessagesDb.markInboundGroupRead(
      widget.userId,
      widget.group.id,
    );
    if (waterline == null) return;

    _readReceiptDebounce?.cancel();
    _readReceiptDebounce = Timer(const Duration(milliseconds: 100), () async {
      if (_settings.sendReadReceipts) {
        await _readReceiptService.sendWaterline(waterline);
      }
    });
  }

  Future<void> _applyReadReceiptUpdate(ReadReceiptUpdate update) async {
    if (!mounted || !_settings.sendReadReceipts) return;
    if (update.groupId != widget.group.id) return;

    final requiredReadCount = _memberCount > 1 ? _memberCount - 1 : 1;
    final refreshed = await refreshOutboundReadStatus(
      messages: _messages.messages,
      localUserId: widget.userId,
      readReceiptsEnabled: _settings.sendReadReceipts,
      groupId: widget.group.id,
      requiredReadCount: requiredReadCount,
    );
    if (!mounted) return;

    setState(() {
      for (final updated in refreshed) {
        if (updated.authorId != widget.userId) continue;
        try {
          final old = _messages.messages.firstWhere((m) => m.id == updated.id);
          if (old.seenAt == updated.seenAt &&
              old.metadata?['deliveryStatus'] ==
                  updated.metadata?['deliveryStatus']) {
            continue;
          }
          _messages.updateMessage(old, updated);
        } catch (_) {}
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

  Future<Uint8List> _decryptGroupImageFromDb(String messageId) async {
    final rows = await MessagesDb.getMessageById(
      messageId,
      groupId: widget.group.id,
    );
    if (rows.isEmpty) {
      throw StateError('Group image not found: $messageId');
    }
    return _decryptGroupFileBytes(rows.first);
  }

  String _mimeTypeForImageBytes(Uint8List bytes) {
    return ImageAttachmentCache.sniffImageMimeType(bytes);
  }

  Future<List<Message>> _decryptBatch(List<Map<String, dynamic>> raw) async {
    final groupKey = await _groupService.getDecryptedGroupKey(widget.group.id);
    if (groupKey == null) return [];

    final List<Message> result = [];
    var inboundDecryptFailures = 0;
    for (final msg in raw) {
      final msgTimestamp = msg['timestamp'] as int;
      if (_joinedAt != null && msgTimestamp < _joinedAt!) {
        continue;
      }
      try {
        final type = msg['type'] as String;
        final authorId = msg['senderId'] as String;
        final createdAt = DateTime.fromMillisecondsSinceEpoch(msg['timestamp'] as int);
        final id = MessagesDb.wireIdFromStorage(msg['id'] as String);
        final replyTo = msg['replyTo'] as String?;
        final meta = metadataFromDbRow(msg);

        final wire = msg['message'];
        if (meta['deleted'] == true || wire == null || (wire is String && wire.isEmpty)) {
          result.add(TextMessage(
            authorId: authorId,
            createdAt: createdAt,
            id: id,
            replyToMessageId: replyTo,
            text: '',
            metadata: {...meta, 'deleted': true},
          ));
          continue;
        }

        if (type == groupTextType) {
          final text = GroupCrypto.decryptText(groupKey, wire as String);
          result.add(TextMessage(
            authorId: authorId,
            createdAt: createdAt,
            id: id,
            text: text,
            replyToMessageId: replyTo,
            metadata: meta.isEmpty ? null : meta,
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
              source: '',
              metadata: const {'viewOnce': true, 'viewed': false},
            ));
          } else {
            result.add(ImageMessage(
              id: id,
              authorId: authorId,
              createdAt: createdAt,
              replyToMessageId: replyTo,
              size: msg['fileSize'] as int? ?? 0,
              source: deferredImageSourceFor(id),
              metadata: meta.isEmpty ? null : meta,
            ));
          }
        } else if (type == groupFileType || type == groupAudioType) {
          final bytes = GroupCrypto.decryptGroupFile(groupKey, msg['message'] as String);
          if (type == groupAudioType) {
            final cacheDir = await getTemporaryDirectory();
            final cachePath = '${cacheDir.path}/group_voice_$id.wav';
            await File(cachePath).writeAsBytes(bytes);
            final durationMs = WaveformExtractor.estimateDurationMs(bytes);
            final peaks = WaveformExtractor.extractPeaks(bytes);
            result.add(FileMessage(
              id: id,
              authorId: authorId,
              createdAt: createdAt,
              replyToMessageId: replyTo,
              name: msg['fileName'] as String? ?? 'voice_message.wav',
              size: bytes.length,
              source: 'audio:$durationMs:$cachePath',
              metadata: {'waveform': WaveformExtractor.encodePeaks(peaks)},
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
              source: base64Encode(bytes),
            ));
          }
        }
      } catch (_) {
        if ((msg['senderId'] as String) != widget.userId) {
          inboundDecryptFailures++;
        }
        result.add(TextMessage(
          authorId: msg['senderId'] as String,
          createdAt: DateTime.fromMillisecondsSinceEpoch(msg['timestamp'] as int),
          id: MessagesDb.wireIdFromStorage(msg['id'] as String),
          text: 'Unable to decrypt message',
          metadata: const {'decryptFailed': true},
        ));
      }
    }

    if (inboundDecryptFailures >= 2) {
      final exists = await DBHelper.getGroupById(widget.group.id);
      if (exists != null) {
        await _groupService.abandonGroupAfterRemoval(widget.group.id);
        if (mounted) _onRemovedFromGroup();
      }
    }

    final withReactions = await _attachReactions(result);
    return _attachOutboundStatus(withReactions, raw);
  }

  Future<List<Message>> _attachOutboundStatus(
    List<Message> messages,
    List<Map<String, dynamic>> rawRows,
  ) async {
    final readReceiptsEnabled = _settings.sendReadReceipts;
    final outboundWireIds = <String>[];
    final rowByWireId = <String, Map<String, dynamic>>{};

    for (final row in rawRows) {
      final wireId = MessagesDb.wireIdFromStorage(row['id'] as String);
      if (row['senderId'] == widget.userId) {
        outboundWireIds.add(wireId);
        rowByWireId[wireId] = row;
      }
    }

    if (outboundWireIds.isEmpty) return messages;

    final receipts = await MessageReadReceiptsDb.getReceiptsForMessages(
      outboundWireIds,
      groupId: widget.group.id,
    );

    final requiredReadCount = _memberCount > 1 ? _memberCount - 1 : 1;

    return messages.map((m) {
      final row = rowByWireId[m.id];
      if (row == null) return m;
      final status = outboundStatusFromDbRow(
        row: row,
        localUserId: widget.userId,
        readReceiptsEnabled: readReceiptsEnabled,
        receipts: receipts[m.id] ?? const [],
        requiredReadCount: requiredReadCount,
      );
      return applyOutboundStatus(m, status: status);
    }).toList();
  }

  Future<void> _loadMoreMessages() async {
    if (_loading || !_hasMore) return;
    _loading = true;

    final batch = await MessagesDb.getMessagesForGroupBatch(
      widget.group.id,
      limit: 20,
      beforeTimestamp: _oldestTimestamp,
      beforeId: _oldestMessageId,
      afterTimestamp: _joinedAt,
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
        messageWithPendingStatus(
          TextMessage(
            authorId: _user.id,
            createdAt: DateTime.now(),
            id: messageId,
            text: text,
            replyToMessageId: replyToId,
          ),
        ),
        index: _messages.messages.length,
      );
      _replyToMessage = null;
    });
    _scheduleScrollToBottomAfterSend();
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
          messageWithPendingStatus(
            FileMessage(
              authorId: _user.id,
              createdAt: DateTime.now(),
              id: messageId,
              name: fileName,
              size: bytes.length,
              source: base64Encode(bytes),
            ),
          ),
          index: _messages.messages.length,
        );
      } else if (type == 'image') {
        _messages.insertMessage(
          messageWithPendingStatus(
            ImageMessage(
              authorId: _user.id,
              createdAt: DateTime.now(),
              id: messageId,
              size: bytes.length,
              source:
                  'data:${_mimeTypeForImageBytes(bytes)};base64,${base64Encode(bytes)}',
              metadata: viewOnce ? const {'viewOnce': true, 'viewed': false} : null,
            ),
          ),
          index: _messages.messages.length,
        );
      }
    });
    _scheduleScrollToBottomAfterSend();

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

    final viewOnce = await ImageSendPreviewScreen.open(context, bytes);
    if (viewOnce == null || !mounted) return;

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
    final peaks = WaveformExtractor.extractPeaks(bytes);

    if (!mounted) return;

    setState(() {
      _messages.insertMessage(
        messageWithPendingStatus(
          FileMessage(
            authorId: _user.id,
            createdAt: DateTime.now(),
            id: messageId,
            name: 'voice_message.wav',
            size: bytes.length,
            source: 'audio:$durationMs:$cachePath',
            metadata: {'waveform': WaveformExtractor.encodePeaks(peaks)},
          ),
        ),
        index: _messages.messages.length,
      );
    });
    _scheduleScrollToBottomAfterSend();

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
              setState(() {
                _memberCount = members.length;
                _groupMemberIds = members.map((m) => m.memberId).toList();
              });
              await _resolveSenderNames(_groupMemberIds);
            }
            widget.reloadConversations();
          },
          onLeftOrDeleted: () {
            widget.onCloseChat?.call();
            widget.reloadConversations();
          },
          onArchived: () {
            Navigator.of(context).pop();
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
    _listScrollController.removeListener(_onListScroll);
    _listScrollController.dispose();
    super.dispose();
  }

  String _deliveryStatusLabel(Message message) {
    if (message.metadata?['failed'] == true) return 'Failed';
    if (isOutboundPending(message)) return 'Pending';
    if (_settings.sendReadReceipts && message.seenAt != null) return 'Read';
    if (message.sentAt != null) return 'Delivered';
    return 'Pending';
  }

  void _openMessageInfo(Message message) {
    ReadReceiptDetailsSheet.show(
      context,
      messageId: message.id,
      localUserId: widget.userId,
      groupId: widget.group.id,
      messageAuthorId: message.authorId,
      groupMemberIds: _groupMemberIds,
      deliveryStatusLabel: _deliveryStatusLabel(message),
      showReadSection: _settings.sendReadReceipts,
    );
  }

  Widget _buildStatusWidget(Message message, bool isSentByMe, Color tickColor) {
    return MessageStatusIcon(
      message: message,
      isSentByMe: isSentByMe,
      tickColor: tickColor,
      readReceiptsEnabled: _settings.sendReadReceipts,
      onRetry: () => _resendMessage(message),
    );
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
                LinkedMessageText(
                  text: message.text,
                  textColor: isSentByMe
                      ? Theme.of(context).colorScheme.onPrimary
                      : Theme.of(context).colorScheme.onSecondary,
                  fontSize: 16,
                  onOpenUrl: _openUrl,
                ),
                const SizedBox(height: 4),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (message.metadata?['edited'] == true) ...[
                      Text(
                        'edited',
                        style: TextStyle(
                          fontSize: 10,
                          fontStyle: FontStyle.italic,
                          color: tickColor.withAlpha(180),
                        ),
                      ),
                      const SizedBox(width: 4),
                    ],
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

    return ImageMessageBubble(
      message: message,
      isSentByMe: isSentByMe,
      timeString: timeString,
      tickWidget: tickWidget,
      decryptFromDb: () => _decryptGroupImageFromDb(message.id),
      senderLabel: _senderLabel(message.authorId, isSentByMe),
    );
  }

  Widget _groupFileMessageBuilder(
    BuildContext context,
    FileMessage message,
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

    if (message.name.contains('voice_message') ||
        message.source.startsWith('audio:')) {
      return Column(
        crossAxisAlignment:
            isSentByMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          _senderLabel(message.authorId, isSentByMe),
          VoiceMessageBubble(
            message: message,
            isSentByMe: isSentByMe,
            timeString: timeString,
            tickWidget: _buildStatusWidget(message, isSentByMe, tickColor),
          ),
        ],
      );
    }

    return FileAttachmentBubble(
      fileName: message.name,
      fileSize: message.size,
      timeString: timeString,
      isSentByMe: isSentByMe,
      tickWidget: _buildStatusWidget(message, isSentByMe, tickColor),
      header: _senderLabel(message.authorId, isSentByMe),
      resolveBytes: () => FileAttachmentResolver.resolve(message),
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
        child: Chat(
          currentUserId: _user.id,
          resolveUser: (id) async => User(id: id),
          chatController: _messages,
          theme: ChatTheme.fromThemeData(Theme.of(context)),
          onMessageSend: _handleSendText,
          builders: Builders(
            chatAnimatedListBuilder: (context, itemBuilder) {
              return ChatAnimatedList(
                scrollController: _listScrollController,
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
                          behavior: HitTestBehavior.translucent,
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
                          onHorizontalDragUpdate: (details) {
                            setState(() {
                              double delta = details.delta.dx;
                              if (isSentByMe) delta = -delta;
                              _dragOffsets[message.id] =
                                  (_dragOffsets[message.id] ?? 0) + delta;
                              if (_dragOffsets[message.id]! < 0) {
                                _dragOffsets[message.id] = 0;
                              }
                              if (_dragOffsets[message.id]! > 100) {
                                _dragOffsets[message.id] = 100;
                              }
                            });
                          },
                          onHorizontalDragEnd: (details) {
                            setState(() {
                              if ((_dragOffsets[message.id] ?? 0) > 50) {
                                _replyToMessage = message;
                              }
                              _dragOffsets[message.id] = 0;
                            });
                          },
                          child: Transform.translate(
                            offset: Offset(
                              isSentByMe
                                  ? -(_dragOffsets[message.id] ?? 0)
                                  : (_dragOffsets[message.id] ?? 0),
                              0,
                            ),
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
                                      Flexible(
                                        child: Column(
                                          crossAxisAlignment: isSentByMe
                                              ? CrossAxisAlignment.end
                                              : CrossAxisAlignment.start,
                                          children: [
                                            if (isMessageDeleted(message))
                                              _senderLabel(
                                                message.authorId,
                                                isSentByMe,
                                              ),
                                            _displayChildForMessage(
                                              message,
                                              child,
                                              isSentByMe,
                                            ),
                                            if (!isMessageDeleted(message))
                                              _reactionBarFor(message, isSentByMe),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
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
              return PrysmChatComposerOverlay(
                replyPreview: _replyToMessage != null
                    ? _buildReplyPreview()
                    : null,
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
