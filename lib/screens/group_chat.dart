import 'package:flutter/widgets.dart';
import 'package:prysm/ui/core/prysm_button.dart';
import 'package:prysm/ui/core/prysm_dialog.dart';
import 'package:prysm/ui/core/prysm_icons.dart';
import 'package:prysm/ui/core/prysm_app.dart';
import 'package:prysm/ui/core/prysm_list_row.dart';
import 'package:prysm/ui/core/prysm_text_field.dart';
import 'package:prysm/ui/core/prysm_toast.dart';
import 'package:prysm/ui/prysm_scaffold.dart';
import 'package:prysm/theme/prysm_style_scope.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:prysm/models/chat/prysm_message.dart';
import 'package:prysm/ui/chat/prysm_chat_message_list.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:prysm/constants/group_constants.dart';
import 'package:prysm/database/message_reactions.dart';
import 'package:prysm/database/messages.dart';
import 'package:prysm/models/contact.dart';
import 'package:prysm/models/reply_preview_data.dart';
import 'package:prysm/services/message_draft_store.dart';
import 'package:prysm/models/group.dart';
import 'package:prysm/screens/group_settings_screen.dart';
import 'package:prysm/ui/chat/prysm_bubble_renderer.dart';
import 'package:prysm/ui/chat/prysm_chat_composer_column.dart';
import 'package:prysm/ui/chat/prysm_chat_list.dart';
import 'package:prysm/ui/chat/prysm_message_row.dart';
import 'package:prysm/util/chat_scroll.dart';
import 'package:prysm/util/logging.dart';
import 'package:prysm/util/scroll_to_chat_message.dart';
import 'package:prysm/screens/widgets/contact_avatar.dart';
import 'package:prysm/screens/widgets/message_reaction_bar.dart';
import 'package:prysm/screens/widgets/message_reaction_picker.dart';
import 'package:prysm/screens/widgets/file_attachment_bubble.dart';
import 'package:prysm/screens/widgets/linked_message_text.dart';
import 'package:prysm/screens/widgets/voice_message_bubble.dart';
import 'package:prysm/screens/widgets/image_message_bubble.dart';
import 'package:prysm/screens/widgets/prysm_chat_drop_target.dart';
import 'package:prysm/util/chat_attachment_ingress.dart';
import 'package:prysm/util/file_transfer_policy.dart';
import 'package:prysm/screens/widgets/quoted_reply_preview.dart';
import 'package:prysm/screens/widgets/quoted_reply_preview_loader.dart';
import 'package:prysm/util/reply_preview_label.dart';
import 'package:prysm/constants/media_constants.dart';
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
import 'package:prysm/util/notification_service.dart';
import 'package:prysm/util/reaction_refresh_notifier.dart';
import 'package:prysm/util/waveform_extractor.dart';
import 'package:prysm/services/detached_chat_client.dart';
import 'package:prysm/services/group_chat_service.dart';
import 'package:prysm/services/group_service.dart';
import 'package:prysm/services/typing_indicator_service.dart';
import 'package:prysm/services/typing_state_tracker.dart';
import 'package:prysm/util/typing_indicator_notifier.dart';
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
  final Widget? torStatusAction;
  final DetachedChatClient? detachedClient;

  const GroupChatScreen({
    required this.userId,
    required this.group,
    required this.contacts,
    required this.keyManager,
    required this.reloadConversations,
    this.onCloseChat,
    this.torStatusAction,
    this.detachedClient,
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
  StreamSubscription? _detachedInboundSub;
  StreamSubscription? _detachedStatusSub;
  StreamSubscription? _membershipSub;
  StreamSubscription? _readReceiptRefreshSub;
  Timer? _readReceiptDebounce;
  List<String> _groupMemberIds = [];
  String? _highlightedMessageId;
  Timer? _highlightTimer;

  Message? _replyToMessage;
  ReplyPreviewData? _replyDraft;
  final Set<String> selectedMessageIds = {};
  final ValueNotifier<double> _swipeDragOffset = ValueNotifier(0);
  String? _swipeDragMessageId;
  late TypingIndicatorService _typingService;
  final _typingTracker = TypingStateTracker();
  StreamSubscription<TypingIndicatorEvent>? _typingSub;
  StreamSubscription<void>? _typingTrackerSub;

  @override
  void initState() {
    super.initState();
    _listScrollController.addListener(_onListScroll);
    _bootstrapForGroup();
  }

  void _onListScroll() {
    final atBottom = isChatScrolledToBottom(_listScrollController);
    if (atBottom == _stickToBottom) return;
    setState(() => _stickToBottom = atBottom);
  }

  String get _draftKey => 'group:${widget.group.id}';

  String? get _replyToMessageId => _replyToMessage?.id ?? _replyDraft?.messageId;

  void _persistReplyDraft() {
    final data = _replyToMessage != null
        ? replyPreviewFromMessage(_replyToMessage!)
        : _replyDraft;
    MessageDraftStore.instance.setReply(_draftKey, data);
  }

  void _restoreReplyDraft() {
    final stored = MessageDraftStore.instance.get(_draftKey).reply;
    if (stored == null) return;
    Message? found;
    for (final message in _messages.messages) {
      if (message.id == stored.messageId) {
        found = message;
        break;
      }
    }
    setState(() {
      _replyToMessage = found;
      _replyDraft = found == null ? stored : null;
    });
  }

  void _clearReplyState() {
    _replyToMessage = null;
    _replyDraft = null;
    MessageDraftStore.instance.setReply(_draftKey, null);
  }

  void _setReplyToMessage(Message message) {
    setState(() {
      _replyToMessage = message;
      _replyDraft = null;
    });
    _persistReplyDraft();
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
    _typingService = TypingIndicatorService.group(
      userId: widget.userId,
      groupId: widget.group.id,
      memberIds: const [],
      settings: _settings,
    );
    _typingSub = TypingIndicatorNotifier.instance.events.listen(_onTypingEvent);
    _typingTrackerSub = _typingTracker.onChanged.listen((_) {
      if (mounted) setState(() {});
    });
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
      _detachedStatusSub =
          widget.detachedClient!.onStatusUpdates.listen((update) {
        _handleStatusUpdate(
          GroupMessageStatusUpdate(
            update['messageId'] as String,
            update['status'] as String,
          ),
        );
      });
    }
    _init();
  }

  @override
  void didUpdateWidget(GroupChatScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.group.id != widget.group.id) {
      _teardown();
      _messages = InMemoryChatController();
      _replyToMessage = null;
      _replyDraft = null;
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
    _typingService.dispose();
    _typingSub?.cancel();
    _typingTrackerSub?.cancel();
    _typingTracker.clearConversation(widget.group.id);
    _newMessagesSub?.cancel();
    _statusSub?.cancel();
    _reactionSub?.cancel();
    _reactionRefreshSub?.cancel();
    _modifyRefreshSub?.cancel();
    _detachedInboundSub?.cancel();
    _detachedStatusSub?.cancel();
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
    showPrysmToast(context, 'You are no longer in this group');
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
    _typingService.dispose();
    _typingService = TypingIndicatorService.group(
      userId: widget.userId,
      groupId: widget.group.id,
      memberIds: _groupMemberIds,
      settings: _settings,
    );

    final ok = await _chatService.initialize();
    if (!ok && mounted) {
      showPrysmToast(context, 'Waiting for group key…');
      _waitForGroupKey();
    }

    if (widget.detachedClient == null) {
      _newMessagesSub = _chatService.onNewMessages.listen(_handleNewMessages);
      _statusSub = _chatService.onMessageStatus.listen(_handleStatusUpdate);
    }
    _reactionSub = _reactionService.onReactionsChanged.listen(_applyReactionUpdate);
    _reactionRefreshSub =
        ReactionRefreshNotifier.instance.onReactionChanged.listen(_applyReactionUpdate);
    _modifyRefreshSub = MessageModifyRefreshNotifier.instance.onModifyChanged
        .listen(_applyModifyUpdate);
    _readReceiptRefreshSub =
        ReadReceiptRefreshNotifier.instance.onReadReceiptChanged
            .listen(_applyReadReceiptUpdate);

    await _loadMoreMessages();
    _restoreReplyDraft();
    await _markInboundAsRead();
    if (widget.detachedClient == null) {
      _chatService.startPolling();
      _chatService.startSendQueue();
      _chatService.pinMembersForWebSocket();
    }

    if (mounted && _messages.messages.isNotEmpty) {
      _stickToBottom = true;
      scheduleScrollChatToBottom(_messages, isMounted: () => mounted);
    }

    if (mounted) setState(() {});
  }

  void _onTypingEvent(TypingIndicatorEvent event) {
    if (event.groupId != widget.group.id) return;
    if (event.senderId == widget.userId) return;

    _typingTracker.applyEvent(
      conversationKey: widget.group.id,
      senderId: event.senderId,
      typing: event.typing,
      timestamp: event.timestamp,
    );
  }

  List<String> _typingTypistNames() {
    if (!_settings.enableTypingIndicators) return const [];
    return _typingTracker
        .activeTypists(widget.group.id)
        .map((id) => _senderNames[id] ?? id)
        .toList(growable: false);
  }

  void _onComposerTypingChanged(bool isTyping) {
    _typingService.onComposerTypingChanged(isTyping);
  }

  Widget _buildReplyPreview() {
    final data = _replyToMessage != null
        ? replyPreviewFromMessage(_replyToMessage!)
        : _replyDraft;
    if (data == null) return const SizedBox.shrink();
    final authorName = data.authorId == widget.userId
        ? 'You'
        : _senderNames[data.authorId];
    return DecoratedBox(
      decoration: BoxDecoration(
        color: context.prysmStyle.tokens.surfaceElevated,
        border: Border(
          left: BorderSide(
            color: context.prysmStyle.tokens.accent,
            width: 3,
          ),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 6, 0, 6),
        child: Row(
          children: [
            Expanded(
              child: QuotedReplyPreview(
                data: data,
                isSentByMe: true,
                compact: true,
                authorName: authorName,
              ),
            ),
            PrysmIconButton(
              icon: PrysmIcons.close,
              onPressed: () => setState(_clearReplyState),
            ),
          ],
        ),
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
          PrysmListRow(
            leading: const Icon(PrysmIcons.editOutlined),
            title: 'Edit',
            onTap: () {
              Navigator.pop(context);
              _editMessage(message);
            },
          ),
        if (isSentByMe)
          PrysmListRow(
            leading: const Icon(PrysmIcons.infoOutline),
            title: 'Info',
            onTap: () {
              Navigator.pop(context);
              _openMessageInfo(message);
            },
          ),
        PrysmListRow(
          leading: const Icon(PrysmIcons.reply),
          title: 'Reply',
          onTap: () {
            Navigator.pop(context);
            _setReplyToMessage(message);
          },
        ),
        PrysmListRow(
          leading: const Icon(PrysmIcons.selectAll),
          title: 'Select',
          onTap: () {
            Navigator.pop(context);
            setState(() => selectedMessageIds.add(message.id));
          },
        ),
        PrysmListRow(
          leading: const Icon(PrysmIcons.deleteOutline),
          title: isSentByMe ? 'Delete for everyone' : 'Delete',
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
    String? newText;
    await showPrysmDialog(
      context: context,
      title: 'Edit message',
      content: PrysmTextField(
        controller: controller,
        autofocus: true,
        maxLines: 4,
        minLines: 1,
        hintText: 'Message',
      ),
      cancelLabel: 'Cancel',
      confirmLabel: 'Save',
      onConfirm: () => newText = controller.text.trim(),
    );
    if (newText == null || newText!.isEmpty || newText == message.text) return;
    final editedText = newText!;

    final ok = await _modifyService.editTextMessage(
      targetMessageId: message.id,
      newText: editedText,
    );
    if (!mounted) return;
    if (ok) {
      setState(() {
        _messages.updateMessage(
          message,
          message.copyWith(
            text: editedText,
            metadata: {...?message.metadata, 'edited': true},
          ),
        );
      });
    } else {
      showPrysmToast(context, 'Could not edit message');
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
              context.prysmStyle.tokens.textPrimary.withAlpha(180),
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

  Widget _replyQuoteFor(Message message, bool isSentByMe) {
    return QuotedReplyPreviewLoader(
      replyToMessageId: message.replyToMessageId,
      messages: _messages.messages,
      isSentByMe: isSentByMe,
      groupId: widget.group.id,
      authorNameFor: (authorId) => _senderNames[authorId],
      onTap: (id) => unawaited(_scrollToMessage(id)),
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
    final decrypted = await _decryptForDisplay(raw);
    if (!mounted) return;
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

    unawaited(
      NotificationService().cancelConversationNotificationIfForeground(
        groupId: widget.group.id,
        senderId: widget.group.id,
      ),
    );

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
    return await GroupCrypto.decryptGroupFile(groupKey, msg['message'] as String);
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

  Future<List<Message>> _decryptForDisplay(List<Map<String, dynamic>> raw) async {
    if (widget.detachedClient != null) {
      return widget.detachedClient!.decryptRows(raw);
    }
    return _decryptBatch(raw);
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
        if (rowShowsAsDeleted(msg, meta)) {
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
          final wireStr = wire as String;
          final text = GroupCrypto.isSenderKeyEnvelope(wireStr)
              ? await GroupCrypto.decryptWithSenderKey(
                  epochKey: groupKey,
                  groupId: widget.group.id,
                  wire: wireStr,
                  transportSenderId: authorId,
                  keyManager: widget.keyManager,
                )
              : await GroupCrypto.decryptText(groupKey, wireStr);
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
          final fileName = msg['fileName'] as String? ??
              (type == groupAudioType ? 'voice_message.wav' : 'file');
          result.add(FileMessage(
            id: id,
            authorId: authorId,
            createdAt: createdAt,
            replyToMessageId: replyTo,
            name: fileName,
            size: (msg['fileSize'] as num?)?.toInt() ?? 0,
            source: wire as String,
            metadata: meta.isEmpty ? null : meta,
          ));
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

    final decrypted = await _decryptForDisplay(sorted);
    if (!mounted) {
      _loading = false;
      return;
    }

    setState(() {
      _messages.insertAllMessages(decrypted, index: 0);
      _oldestTimestamp = batch.last['timestamp'] as int;
      _oldestMessageId = batch.last['id'] as String;
      _loading = false;
    });
  }

  void _handleSendText(String text) async {
    final messageId = const Uuid().v4();
    final replyToId = _replyToMessageId;
    setState(() {
      _messages.insertMessage(
        messageWithPendingStatus(
          TextMessage(
            authorId: widget.userId,
            createdAt: DateTime.now(),
            id: messageId,
            text: text,
            replyToMessageId: replyToId,
          ),
        ),
        index: _messages.messages.length,
      );
      _replyToMessage = null;
      _replyDraft = null;
    });
    MessageDraftStore.instance.setReply(_draftKey, null);
    _scheduleScrollToBottomAfterSend();
    if (widget.detachedClient != null) {
      final sentId = await widget.detachedClient!.sendText(
        text: text,
        replyToId: replyToId,
        messageId: messageId,
      );
      if (sentId == null && mounted) {
        showPrysmToast(context, 'Could not send message — group key unavailable');
      }
      return;
    }
    final sentId = await _chatService.sendTextMessage(
      text,
      messageId: messageId,
      replyToId: replyToId,
    );
    if (sentId == null && mounted) {
      showPrysmToast(context, 'Could not send message — group key unavailable');
    }
    widget.reloadConversations();
  }

  bool _rejectOversizedFile(int byteLength) {
    if (FileTransferPolicy.isWithinMaxFileSize(byteLength)) {
      return false;
    }
    if (mounted) {
      showPrysmToast(context, FileTransferPolicy.maxFileSizeError);
    }
    return true;
  }

  void _removeOptimisticFileMessage(String messageId) {
    if (!mounted) return;
    setState(() {
      final idx = _messages.messages.indexWhere((m) => m.id == messageId);
      if (idx != -1) {
        _messages.removeMessage(_messages.messages[idx]);
        selectedMessageIds.remove(messageId);
      }
    });
  }

  void _sendFile(Uint8List bytes, String fileName, String type, {bool viewOnce = false}) async {
    if (_rejectOversizedFile(bytes.length)) {
      return;
    }

    final messageId = const Uuid().v4();
    final replyToId = _replyToMessageId;
    setState(() {
      if (type == 'file') {
        _messages.insertMessage(
          messageWithPendingStatus(
            FileMessage(
              authorId: widget.userId,
              createdAt: DateTime.now(),
              id: messageId,
              replyToMessageId: replyToId,
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
              authorId: widget.userId,
              createdAt: DateTime.now(),
              id: messageId,
              replyToMessageId: replyToId,
              size: bytes.length,
              source:
                  'data:${_mimeTypeForImageBytes(bytes)};base64,${base64Encode(bytes)}',
              metadata: viewOnce ? const {'viewOnce': true, 'viewed': false} : null,
            ),
          ),
          index: _messages.messages.length,
        );
      }
      _replyToMessage = null;
      _replyDraft = null;
    });
    MessageDraftStore.instance.setReply(_draftKey, null);
    _scheduleScrollToBottomAfterSend();

    if (widget.detachedClient != null) {
      final sentId = await widget.detachedClient!.sendFile(
        bytes: bytes,
        fileName: fileName,
        type: type,
        replyToId: replyToId,
        messageId: messageId,
        viewOnce: viewOnce,
      );
      if (!mounted) return;
      if (sentId == null) {
        _removeOptimisticFileMessage(messageId);
        showPrysmToast(context, 'Could not send file — group key unavailable');
      }
      return;
    }

    final sentId = await _chatService.sendFileMessage(
      bytes,
      fileName,
      type,
      messageId: messageId,
      viewOnce: viewOnce,
      replyToId: replyToId,
    );
    if (!mounted) return;
    if (sentId != null) {
      widget.reloadConversations();
      return;
    }

    final stored = await MessagesDb.getMessageById(
      messageId,
      groupId: widget.group.id,
    );
    if (stored.isEmpty) {
      _removeOptimisticFileMessage(messageId);
      return;
    }

    if (!mounted) return;
    showPrysmToast(context, 'Message queued. Will send when members are reachable.');
    widget.reloadConversations();
  }

  Future<void> _handleSendImage() async {
    final picker = ImagePicker();
    final pickedFile = await picker.pickImage(source: ImageSource.gallery);
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
    final messageId = const Uuid().v4();
    final replyToId = _replyToMessageId;
    final cacheDir = await getTemporaryDirectory();
    final cachePath = '${cacheDir.path}/group_voice_cache_$messageId.wav';
    await File(cachePath).writeAsBytes(bytes);
    final peaks = WaveformExtractor.extractPeaks(bytes);

    if (!mounted) return;

    setState(() {
      _messages.insertMessage(
        messageWithPendingStatus(
          FileMessage(
            authorId: widget.userId,
            createdAt: DateTime.now(),
            id: messageId,
            replyToMessageId: replyToId,
            name: 'voice_message.wav',
            size: bytes.length,
            source: 'audio:$durationMs:$cachePath',
            metadata: {'waveform': WaveformExtractor.encodePeaks(peaks)},
          ),
        ),
        index: _messages.messages.length,
      );
      _replyToMessage = null;
      _replyDraft = null;
    });
    MessageDraftStore.instance.setReply(_draftKey, null);
    _scheduleScrollToBottomAfterSend();

    if (widget.detachedClient != null) {
      await widget.detachedClient!.sendVoice(
        bytes: bytes,
        durationMs: durationMs,
        messageId: messageId,
      );
      return;
    }

    await _chatService.sendFileMessage(
      bytes,
      'voice_message.wav',
      'audio',
      messageId: messageId,
      replyToId: replyToId,
    );
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
          color: context.prysmStyle.tokens.accent,
        ),
      ),
    );
  }

  void _openSettings() async {
    final result = await Navigator.of(context).push(
      PrysmPageRoute(page: GroupSettingsScreen(
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

    if (result is String) {
      await _scrollToMessage(result);
    }
  }

  Future<void> _scrollToMessage(String messageId) async {
    final found = await scrollToChatMessage(
      controller: _messages,
      messageId: messageId,
      loadMore: () async {
        if (!_hasMore || _loading) return false;
        final countBefore = _messages.messages.length;
        await _loadMoreMessages();
        return _messages.messages.length > countBefore;
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
    } else {
      showPrysmToast(context, 'Message not found in loaded history');
    }
  }

  @override
  void dispose() {
    _teardown();
    _typingTracker.dispose();
    _highlightTimer?.cancel();
    _swipeDragOffset.dispose();
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
  }) {
    final msgDate = DateTime.fromMillisecondsSinceEpoch(
      message.createdAt!.millisecondsSinceEpoch,
    );
    final timeString =
        '${msgDate.hour.toString().padLeft(2, '0')}:${msgDate.minute.toString().padLeft(2, '0')}';

    final tickColor = isSentByMe
        ? context.prysmStyle.tokens.onAccent.withAlpha(200)
        : context.prysmStyle.tokens.textPrimary.withAlpha(200);

    return Column(
      crossAxisAlignment:
          isSentByMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        _senderLabel(message.authorId, isSentByMe),
        IntrinsicWidth(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: prysmBubbleBackground(context, isSentByMe: isSentByMe),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                _replyQuoteFor(message, isSentByMe),
                LinkedMessageText(
                  text: message.text,
                  textColor: isSentByMe
                      ? context.prysmStyle.tokens.onAccent
                      : context.prysmStyle.tokens.textPrimary,
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
            context.prysmStyle.tokens.onAccent.withAlpha(220),
          )
        : const SizedBox.shrink();

    if (isViewOnce && isViewed) {
      return Column(
        crossAxisAlignment:
            isSentByMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          _senderLabel(message.authorId, isSentByMe),
          _replyQuoteFor(message, isSentByMe),
          Container(
            width: 200,
            height: 60,
            decoration: BoxDecoration(
              color: context.prysmStyle.tokens.surfaceElevated,
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
          _replyQuoteFor(message, isSentByMe),
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
                        PrysmPageRoute(page: _GroupViewOnceScreen(imageBytes: bytes),
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
                      Logging.error('View-once failed: $e', 'GroupChatScreen');
                    }
                  },
            child: Container(
              width: 200,
              height: 200,
              decoration: BoxDecoration(
                color: context.prysmStyle.tokens.surfaceElevated,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: context.prysmStyle.tokens.accent.withAlpha(100),
                  width: 2,
                ),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    PrysmIcons.visibility,
                    size: 40,
                    color: context.prysmStyle.tokens.accent,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    isSentByMe ? 'View Once Photo' : 'Tap to View',
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
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                timeString,
                style: TextStyle(
                  fontSize: 10,
                  color: context.prysmStyle.tokens.textSecondary,
                ),
              ),
              if (isSentByMe) ...[const SizedBox(width: 4), tickWidget],
            ],
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment:
          isSentByMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        _senderLabel(message.authorId, isSentByMe),
        _replyQuoteFor(message, isSentByMe),
        ImageMessageBubble(
          message: message,
          isSentByMe: isSentByMe,
          timeString: timeString,
          tickWidget: tickWidget,
          decryptFromDb: () => _decryptGroupImageFromDb(message.id),
        ),
      ],
    );
  }

  Widget _groupFileMessageBuilder(
    BuildContext context,
    FileMessage message,
    int index, {
    required bool isSentByMe,
  }) {
    final msgDate = DateTime.fromMillisecondsSinceEpoch(
      message.createdAt!.millisecondsSinceEpoch,
    );
    final timeString =
        '${msgDate.hour.toString().padLeft(2, '0')}:${msgDate.minute.toString().padLeft(2, '0')}';
    final tickColor = isSentByMe
        ? context.prysmStyle.tokens.onAccent.withAlpha(200)
        : context.prysmStyle.tokens.textPrimary.withAlpha(200);

    if (message.name.contains('voice_message') ||
        message.source.startsWith('audio:')) {
      return Column(
        crossAxisAlignment:
            isSentByMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          _senderLabel(message.authorId, isSentByMe),
          _replyQuoteFor(message, isSentByMe),
          VoiceMessageBubble(
            message: message,
            isSentByMe: isSentByMe,
            timeString: timeString,
            tickWidget: _buildStatusWidget(message, isSentByMe, tickColor),
            decryptAudio: message.source.startsWith('audio:')
                ? null
                : (_) async {
                    final rows = await MessagesDb.getMessageById(
                      message.id,
                      groupId: widget.group.id,
                    );
                    if (rows.isEmpty) return null;
                    return _decryptGroupFileBytes(rows.first);
                  },
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment:
          isSentByMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        _replyQuoteFor(message, isSentByMe),
        FileAttachmentBubble(
          fileName: message.name,
          fileSize: message.size,
          timeString: timeString,
          isSentByMe: isSentByMe,
          tickWidget: _buildStatusWidget(message, isSentByMe, tickColor),
          header: _senderLabel(message.authorId, isSentByMe),
          resolveBytes: () async {
            final rows = await MessagesDb.getMessageById(
              message.id,
              groupId: widget.group.id,
            );
            if (rows.isEmpty) return Uint8List(0);
            return _decryptGroupFileBytes(rows.first);
          },
        ),
      ],
    );
  }

  Widget _buildGroupTitle() {
    final style = context.prysmStyle;
    return Row(
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
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                widget.group.name,
                style: style.titleStyle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 2),
              Text(
                '$_memberCount members',
                style: style.captionStyle.copyWith(
                  color: style.tokens.textMuted,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return PrysmPage(
      headerHeight: 70,
      leading: PrysmIconButton(
        icon: PrysmIcons.chevronLeft,
        onPressed: () {
          if (widget.onCloseChat != null) {
            widget.onCloseChat!();
          } else {
            Navigator.of(context).maybePop();
          }
        },
      ),
      titleWidget: _buildGroupTitle(),
      actions: [
        if (widget.torStatusAction != null) widget.torStatusAction!,
        if (selectedMessageIds.isNotEmpty)
          PrysmIconButton(
            icon: PrysmIcons.deleteOutline,
            onPressed: _deleteSelectedMessages,
          ),
        PrysmIconButton(
          icon: PrysmIcons.settingsOutlined,
          onPressed: _openSettings,
        ),
      ],
      body: PrysmChatDropTarget(
        onFileDropped: _handleDroppedFile,
        child: Column(
          children: [
            Expanded(
              child: PrysmChatList(
                controller: _messages,
                scrollController: _listScrollController,
                onLoadMore: _loadMoreMessages,
                showJumpToBottom: selectedMessageIds.isEmpty,
                onStickToBottomChanged: (atBottom) {
                  _stickToBottom = atBottom;
                },
                itemBuilder: _buildGroupChatListItem,
              ),
            ),
            PrysmChatComposerColumn(
              draftKey: _draftKey,
              replyPreview: _replyToMessage != null || _replyDraft != null
                  ? _buildReplyPreview()
                  : null,
              typingTypistNames: _typingTypistNames(),
              onSendText: _handleSendText,
              onSendImage: _handleSendImage,
              onSendFile: _handleSendFile,
              onSendVoice: _handleSendVoice,
              onTypingChanged: _onComposerTypingChanged,
            ),
          ],
        ),
      ),
    );
  }

  Widget _groupMessageChildFor(
    BuildContext context,
    Message message,
    int index,
    bool isSentByMe,
  ) {
    if (message is TextMessage) {
      return _groupTextMessageBuilder(
        context,
        message,
        index,
        isSentByMe: isSentByMe,
      );
    }
    if (message is ImageMessage) {
      return _groupImageMessageBuilder(
        context,
        message,
        index,
        isSentByMe: isSentByMe,
      );
    }
    if (message is FileMessage) {
      return _groupFileMessageBuilder(
        context,
        message,
        index,
        isSentByMe: isSentByMe,
      );
    }
    return const SizedBox.shrink();
  }

  Widget _buildGroupChatListItem(
    BuildContext context,
    Message message,
    int index,
  ) {
    final isSentByMe = message.authorId == widget.userId;
    final isSelected = selectedMessageIds.contains(message.id);
    final child = _groupMessageChildFor(context, message, index, isSentByMe);

    return PrysmMessageRow(
      message: message,
      index: index,
      messages: _messages.messages,
      localUserId: widget.userId,
      swipeDragOffset: _swipeDragOffset,
      swipeDragMessageId: _swipeDragMessageId,
      onSwipeMessageIdChanged: (id) => _swipeDragMessageId = id,
      isSelected: isSelected,
      isHighlighted: _highlightedMessageId == message.id,
      selectionActive: selectedMessageIds.isNotEmpty,
      onToggleSelect: () {
        setState(() {
          if (isSelected) {
            selectedMessageIds.remove(message.id);
          } else {
            selectedMessageIds.add(message.id);
          }
        });
      },
      onReply: () {
        setState(() {
          _replyToMessage = message;
          _replyDraft = null;
        });
        _persistReplyDraft();
      },
      onLongPressMenu: (_) => _showMessageMenu(message),
      displayChild: Column(
        crossAxisAlignment:
            isSentByMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isMessageDeleted(message))
            _senderLabel(message.authorId, isSentByMe),
          _displayChildForMessage(message, child, isSentByMe),
        ],
      ),
      reactionBar: isMessageDeleted(message)
          ? const SizedBox.shrink()
          : _reactionBarFor(message, isSentByMe),
    );
  }
}

class _GroupViewOnceScreen extends StatelessWidget {
  final Uint8List imageBytes;

  const _GroupViewOnceScreen({required this.imageBytes});

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
          child: Image.memory(imageBytes),
        ),
      ),
    );
  }
}
