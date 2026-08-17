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
import 'package:prysm/constants/group_constants.dart';
import 'package:prysm/database/messages.dart';
import 'package:prysm/models/contact.dart';
import 'package:prysm/models/group.dart';
import 'package:prysm/screens/group_settings_screen.dart';
import 'package:prysm/ui/chat/prysm_bubble_renderer.dart';
import 'package:prysm/ui/chat/prysm_chat_composer_column.dart';
import 'package:prysm/ui/chat/prysm_constrained_composer.dart';
import 'package:prysm/ui/chat/prysm_date_header.dart';
import 'package:prysm/ui/chat/prysm_chat_list.dart';
import 'package:prysm/ui/chat/chat_search_bar.dart';
import 'package:prysm/ui/chat/prysm_message_row.dart';
import 'package:prysm/util/logging.dart';
import 'package:prysm/util/scroll_to_chat_message.dart';
import 'package:prysm/screens/widgets/message_reaction_bar.dart';
import 'package:prysm/screens/widgets/message_copy_action.dart';
import 'package:prysm/screens/widgets/message_reaction_picker.dart';
import 'package:prysm/screens/widgets/file_attachment_bubble.dart';
import 'package:prysm/screens/widgets/linked_message_text.dart';
import 'package:prysm/screens/widgets/voice_message_bubble.dart';
import 'package:prysm/screens/widgets/image_message_bubble.dart';
import 'package:prysm/screens/widgets/prysm_chat_drop_target.dart';
import 'package:prysm/util/chat_attachment_ingress.dart';
import 'package:prysm/screens/widgets/quoted_reply_preview.dart';
import 'package:prysm/screens/widgets/quoted_reply_preview_loader.dart';
import 'package:prysm/util/reply_preview_label.dart';
import 'package:prysm/constants/media_constants.dart';
import 'package:prysm/screens/widgets/deleted_message_bubble.dart';
import 'package:prysm/screens/widgets/view_once_image_screen.dart';
import 'package:prysm/screens/widgets/disappearing_messages_tile.dart';
import 'package:prysm/services/disappearing_timer_service.dart';
import 'package:prysm/util/disappearing_timer_refresh_notifier.dart';
import 'package:prysm/services/message_modify_service.dart';
import 'package:prysm/services/message_actions_service.dart';
import 'package:prysm/services/message_view_mapper.dart';
import 'package:prysm/services/reaction_service.dart';
import 'package:prysm/services/read_receipt_service.dart';
import 'package:prysm/services/scheduled_message_service.dart';
import 'package:prysm/services/chat_screen_controller.dart';
import 'package:prysm/services/settings_service.dart';
import 'package:prysm/database/message_read_receipts.dart';
import 'package:prysm/screens/widgets/message_status_icon.dart';
import 'package:prysm/screens/widgets/read_receipt_details_sheet.dart';
import 'package:prysm/util/message_status_mapper.dart';
import 'package:prysm/util/read_receipt_refresh_notifier.dart';
import 'package:prysm/util/message_modify_policy.dart';
import 'package:prysm/util/message_modify_refresh_notifier.dart';
import 'package:prysm/util/notification_service.dart';
import 'package:prysm/util/reaction_refresh_notifier.dart';
import 'package:prysm/services/detached_chat_client.dart';
import 'package:prysm/services/group_chat_service.dart';
import 'package:prysm/services/group_service.dart';
import 'package:prysm/services/typing_indicator_service.dart';
import 'package:prysm/services/typing_state_tracker.dart';
import 'package:prysm/util/typing_indicator_notifier.dart';
import 'package:prysm/crypto/group_crypto.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/util/group_membership_notifier.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/peer_identity_loader.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:prysm/l10n/l10n_extensions.dart';

class GroupChatScreen extends StatefulWidget {
  final String userId;
  final Group group;
  final List<Contact> contacts;
  final KeyManager keyManager;
  final VoidCallback reloadConversations;
  final VoidCallback? onCloseChat;
  final Widget? torStatusAction;
  final DetachedChatClient? detachedClient;
  final String? initialScrollToMessageId;

  const GroupChatScreen({
    required this.userId,
    required this.group,
    required this.contacts,
    required this.keyManager,
    required this.reloadConversations,
    this.onCloseChat,
    this.torStatusAction,
    this.detachedClient,
    this.initialScrollToMessageId,
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
  late MessageViewMapper _viewMapper;
  late MessageActionsService _actionsService;
  final _settings = SettingsService();

  late ChatScreenController _controller;
  final ScrollController _listScrollController = ScrollController();
  final Map<String, String> _senderNames = {};
  int _memberCount = 0;

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
  List<String> _groupMemberIds = [];
  String? _highlightedMessageId;
  Timer? _highlightTimer;
  bool _showChatSearch = false;
  String _chatHighlightQuery = '';

  Set<String> get selectedMessageIds => _controller.selectedMessageIds;
  PrysmChatMessageList get _messages => _controller.messages;
  final ValueNotifier<double> _swipeDragOffset = ValueNotifier(0);
  String? _swipeDragMessageId;
  late TypingIndicatorService _typingService;
  final _typingTracker = TypingStateTracker();
  StreamSubscription<TypingIndicatorEvent>? _typingSub;
  StreamSubscription<void>? _typingTrackerSub;
  int? _disappearingTimerSeconds;
  StreamSubscription<String>? _disappearingTimerSub;

  @override
  void initState() {
    super.initState();
    _bootstrapForGroup();
    _listScrollController.addListener(_onListScrollForward);
  }

  String get _draftKey => 'group:${widget.group.id}';

  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  // Stable forwarder registered once in initState so scroll updates always
  // reach the *current* `_controller`, even after didUpdateWidget or _init()
  // rebuild it (group switch / re-init after key wait). Never rebind
  // addListener/removeListener to the controller's own tear-off — that pins
  // the listener to whichever controller instance existed at registration
  // time and it silently stops firing (or throws "used after being
  // disposed") once that instance is replaced.
  void _onListScrollForward() => _controller.onListScroll();

  ChatScreenController _buildController() {
    return ChatScreenController(
      localUserId: widget.userId,
      draftKey: _draftKey,
      listScrollController: _listScrollController,
      isMounted: () => mounted,
      typingTracker: _typingTracker,
      typingService: _typingService,
      conversationKey: widget.group.id,
      matchesTypingEvent: (e) => e.groupId == widget.group.id && e.senderId != widget.userId,
      typingIndicatorsEnabled: () => _settings.enableTypingIndicators,
      typistDisplayName: (id) => _senderNames[id] ?? id,
      reactionService: _reactionService,
      readReceiptService: _readReceiptService,
      markInboundRead: () => MessagesDb.markInboundGroupRead(widget.userId, widget.group.id),
      cancelForegroundNotification: () => unawaited(
        NotificationService().cancelConversationNotificationIfForeground(
          groupId: widget.group.id,
          senderId: widget.group.id,
        ),
      ),
      sendReadReceiptsEnabled: () => _settings.sendReadReceipts,
      readReceiptGroupId: widget.group.id,
      requiredReadCount: () => _memberCount > 1 ? _memberCount - 1 : 1,
      fetchMessageBatch: ({beforeTimestamp, beforeId}) => MessagesDb.getMessagesForGroupBatch(
        widget.group.id,
        limit: 20,
        beforeTimestamp: beforeTimestamp,
        beforeId: beforeId,
        afterTimestamp: _joinedAt,
      ),
      decryptForDisplay: _decryptForDisplay,
      seedNewestTimestamp: _chatService.seedNewestTimestamp,
      onToast: (msg) {
        if (mounted) showPrysmToast(context, msg);
      },
      fileMessageSource: (bytes) => base64Encode(bytes),
      voiceCacheFileNamePrefix: 'group_voice_cache',
      dispatchText: _dispatchText,
      dispatchFile: _dispatchFile,
      dispatchVoice: _dispatchVoice,
    );
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
    _viewMapper = MessageViewMapper(keyManager: widget.keyManager);
    _actionsService = MessageActionsService(
      modifyService: _modifyService,
      groupId: widget.group.id,
    );
    _typingService = TypingIndicatorService.group(
      userId: widget.userId,
      groupId: widget.group.id,
      memberIds: const [],
      settings: _settings,
    );
    _controller = _buildController();
    _controller.addListener(_onControllerChanged);
    _typingSub = TypingIndicatorNotifier.instance.events.listen(_controller.onTypingEvent);
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
        _controller.scheduleScrollToBottomAfterSend();
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
    unawaited(_loadDisappearingTimer());
    _disappearingTimerSub =
        DisappearingTimerRefreshNotifier.instance.onChanged.listen((id) {
      if (id == widget.group.id) unawaited(_loadDisappearingTimer());
    });
  }

  Future<void> _loadDisappearingTimer() async {
    final seconds =
        await DisappearingTimerService.getTimerSeconds(widget.group.id);
    if (!mounted) return;
    setState(() => _disappearingTimerSeconds = seconds);
  }

  @override
  void didUpdateWidget(GroupChatScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.group.id != widget.group.id) {
      setState(() => _disappearingTimerSeconds = null);
      _teardown();
      _senderNames.clear();
      _memberCount = 0;
      _bootstrapForGroup();
      return;
    }
    final scrollId = widget.initialScrollToMessageId;
    if (scrollId != null && scrollId != oldWidget.initialScrollToMessageId) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(_scrollToMessage(scrollId));
      });
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
    _disappearingTimerSub?.cancel();
    _disappearingTimerSub = null;
    _controller.removeListener(_onControllerChanged);
    _controller.dispose();
    _chatService.unpinMembersForWebSocket();
    _chatService.dispose();
    _reactionService.dispose();
  }

  void _onRemovedFromGroup() {
    if (!mounted) return;
    widget.onCloseChat?.call();
    widget.reloadConversations();
    showPrysmToast(context, context.l10n.youAreNoLongerInThisGroup);
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
    _controller.removeListener(_onControllerChanged);
    _controller.dispose();
    _controller = _buildController();
    _controller.addListener(_onControllerChanged);

    final ok = await _chatService.initialize();
    if (!ok && mounted) {
      showPrysmToast(context, context.l10n.waitingForGroupKey);
      _waitForGroupKey();
    }

    if (widget.detachedClient == null) {
      _newMessagesSub = _chatService.onNewMessages.listen(_handleNewMessages);
      _statusSub = _chatService.onMessageStatus.listen(_handleStatusUpdate);
    }
    _reactionSub = _reactionService.onReactionsChanged.listen(_controller.applyReactionUpdate);
    _reactionRefreshSub =
        ReactionRefreshNotifier.instance.onReactionChanged.listen(_controller.applyReactionUpdate);
    _modifyRefreshSub = MessageModifyRefreshNotifier.instance.onModifyChanged
        .listen(_applyModifyUpdate);
    _readReceiptRefreshSub =
        ReadReceiptRefreshNotifier.instance.onReadReceiptChanged
            .listen(_controller.applyReadReceiptUpdate);

    await _controller.loadMoreMessages();
    _controller.restoreReplyDraft();
    await _controller.markInboundAsRead();
    if (widget.detachedClient == null) {
      _chatService.startPolling();
      _chatService.startSendQueue();
      _chatService.pinMembersForWebSocket();
    }

    if (mounted && _controller.messages.messages.isNotEmpty) {
      _controller.scheduleScrollToBottomAfterSend();
    }

    final initialId = widget.initialScrollToMessageId;
    if (initialId != null && mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(_scrollToMessage(initialId));
      });
    }

    if (mounted) setState(() {});
  }

  Widget _buildReplyPreview() {
    final data = _controller.replyToMessage != null
        ? replyPreviewFromMessage(_controller.replyToMessage!)
        : _controller.replyDraft;
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
              onPressed: () => _controller.clearReplyState(),
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
    final text = messageCopyText(message);
    showMessageActionsSheet(
      context: context,
      onReactionSelected: (emoji) => _controller.onReactionSelected(message, emoji),
      actionTiles: [
        if (text.isNotEmpty) copyMessageTile(context: context, text: text),
        if (canEditMessage(message, widget.userId))
          PrysmListRow(
            leading: const Icon(PrysmIcons.editOutlined),
            title: context.l10n.edit,
            onTap: () {
              Navigator.pop(context);
              _editMessage(message);
            },
          ),
        if (isSentByMe)
          PrysmListRow(
            leading: const Icon(PrysmIcons.infoOutline),
            title: context.l10n.info,
            onTap: () {
              Navigator.pop(context);
              _openMessageInfo(message);
            },
          ),
        PrysmListRow(
          leading: const Icon(PrysmIcons.reply),
          title: context.l10n.reply,
          onTap: () {
            Navigator.pop(context);
            _controller.setReplyToMessage(message);
          },
        ),
        PrysmListRow(
          leading: const Icon(PrysmIcons.selectAll),
          title: context.l10n.select,
          onTap: () {
            Navigator.pop(context);
            _controller.selectMessage(message.id);
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

  /// Deletes [message] and returns the outcome, so the bulk path can report a
  /// single aggregated failure instead of one toast per selected message.
  Future<MessageDeleteOutcome> _deleteMessage(
    Message message, {
    bool showFailureToast = true,
  }) async {
    final outcome = await _actionsService.deleteMessage(
      message,
      localUserId: widget.userId,
    );
    if (!mounted) return outcome;
    setState(() {
      if (outcome == MessageDeleteOutcome.markedDeletedForEveryone) {
        _messages.updateMessage(message, markMessageDeleted(message));
      } else if (outcome ==
          MessageDeleteOutcome.markedDeletedForEveryoneFailed) {
        // The tombstone was applied locally, but the peer was not notified:
        // surface the send-failure state (metadata['failed'] -> 'Failed').
        _messages.updateMessage(
          message,
          markMessageDeleted(
            message.copyWith(
              metadata: {...?message.metadata, 'failed': true},
            ),
          ),
        );
      } else {
        _messages.removeMessage(message);
      }
    });
    if (showFailureToast &&
        outcome == MessageDeleteOutcome.markedDeletedForEveryoneFailed) {
      showPrysmToast(context, context.l10n.couldNotDeleteForEveryone);
    }
    return outcome;
  }

  Future<void> _editMessage(Message message) async {
    if (message is! TextMessage) return;
    final controller = TextEditingController(text: message.text);
    String? newText;
    await showPrysmDialog(
      context: context,
      title: context.l10n.editMessage,
      content: PrysmTextField(
        controller: controller,
        autofocus: true,
        maxLines: 4,
        minLines: 1,
        hintText: context.l10n.messageHint,
      ),
      cancelLabel: context.l10n.cancel,
      confirmLabel: context.l10n.save,
      onConfirm: () => newText = controller.text.trim(),
    );
    if (newText == null || newText!.isEmpty || newText == message.text) return;
    final editedText = newText!;

    final updated = await _actionsService.editTextMessage(message, editedText);
    if (!mounted) return;
    if (updated != null) {
      setState(() {
        _messages.updateMessage(message, updated);
      });
    } else {
      showPrysmToast(context, context.l10n.couldNotEditMessage);
    }
  }

  void _applyModifyUpdate(MessageModifyUpdate update) {
    if (!mounted) return;
    try {
      final msg =
          _messages.messages.firstWhere((m) => m.id == update.targetMessageId);
      Message updated;
      if (update.isRemove) {
        setState(() {
          _messages.removeMessage(msg);
        });
        return;
      }
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

  Widget _reactionBarFor(Message message, bool isSentByMe) {
    final reactions = message.reactions;
    if (reactions == null || reactions.isEmpty) {
      return const SizedBox.shrink();
    }
    return MessageReactionBar(
      reactions: reactions,
      currentUserId: widget.userId,
      isSentByMe: isSentByMe,
      onReactionTap: (emoji) => _controller.onReactionSelected(message, emoji),
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
    var failed = 0;
    for (final id in ids) {
      try {
        final msg = _messages.messages.firstWhere((m) => m.id == id);
        final outcome = await _deleteMessage(msg, showFailureToast: false);
        if (outcome == MessageDeleteOutcome.markedDeletedForEveryoneFailed) {
          failed++;
        }
      } catch (_) {}
    }
    if (mounted) {
      _controller.clearSelection();
      // One toast for the whole selection: the per-message toast is
      // suppressed above so N failures do not stack N toasts.
      if (failed > 0) {
        showPrysmToast(
          context,
          failed == 1
              ? 'Could not delete for everyone'
              : 'Could not delete $failed messages for everyone',
        );
      }
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
        await _controller.loadMoreMessages();
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
    _controller.scheduleScrollToBottomIfNeeded();
    await _controller.markInboundAsRead();
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
    return _viewMapper.decryptGroupFileBytes(
      getDecryptedGroupKey: _groupService.getDecryptedGroupKey,
      groupId: widget.group.id,
      row: msg,
    );
  }

  Future<String> _decryptSenderKeyText({
    required Uint8List groupKey,
    required String wire,
    required String transportSenderId,
  }) async {
    final senderKeys = await loadGroupSenderIdentity(
      widget.keyManager,
      transportSenderId,
      localUserId: widget.userId,
    );
    if (senderKeys == null) {
      throw ArgumentError('Unknown sender identity');
    }
    return GroupCryptoV2.decryptWithSenderKey(
      epochKey: groupKey,
      groupId: widget.group.id,
      wire: wire,
      transportSenderId: transportSenderId,
      senderKeys: senderKeys,
    );
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
          final text = GroupCryptoV2.isSenderKeyEnvelope(wireStr)
              ? await _decryptSenderKeyText(
                  groupKey: groupKey,
                  wire: wireStr,
                  transportSenderId: authorId,
                )
              : await GroupCryptoV2.decryptText(groupKey, wireStr);
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
        } else if (type == disappearingTimerNoticeType) {
          final payload = jsonDecode((wire as String?) ?? '{}')
              as Map<String, dynamic>;
          result.add(TextMessage(
            authorId: authorId,
            createdAt: createdAt,
            id: id,
            replyToMessageId: replyTo,
            text: '',
            metadata: {
              'systemNotice': 'disappearing_timer',
              'timerSeconds': payload['timerSeconds'],
              'actorId': payload['actorId'],
            },
          ));
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

  Future<void> _dispatchText({
    required String text,
    required String messageId,
    String? replyToId,
  }) async {
    if (widget.detachedClient != null) {
      final sentId = await widget.detachedClient!.sendText(
        text: text,
        replyToId: replyToId,
        messageId: messageId,
      );
      if (sentId == null && mounted) {
        showPrysmToast(context, context.l10n.couldNotSendMessageGroupKeyUnavailable);
      }
      return;
    }
    final sentId = await _chatService.sendTextMessage(
      text,
      messageId: messageId,
      replyToId: replyToId,
    );
    if (sentId == null && mounted) {
      showPrysmToast(context, context.l10n.couldNotSendMessageGroupKeyUnavailable);
    }
    widget.reloadConversations();
  }

  Future<bool> _scheduleText(String text, DateTime sendAt) async {
    try {
      await ScheduledMessageService(
        userId: widget.userId,
        keyManager: widget.keyManager,
      ).schedule(
        conversationId: widget.group.id,
        isGroup: true,
        text: text,
        sendAt: sendAt,
        replyToId: _controller.replyToMessageId,
      );
    } catch (e) {
      if (mounted) showPrysmToast(context, 'Could not schedule message: $e');
      return false;
    }
    _controller.clearReplyState();
    return true;
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
        _controller.removeOptimisticFileMessage(messageId);
        showPrysmToast(context, context.l10n.couldNotSendFileGroupKeyUnavailable);
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
      _controller.removeOptimisticFileMessage(messageId);
      return;
    }

    if (!mounted) return;
    showPrysmToast(context, context.l10n.messageQueuedWillSendWhenMembersAreReachable);
    widget.reloadConversations();
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

    await _chatService.sendFileMessage(
      bytes,
      'voice_message.wav',
      'audio',
      messageId: messageId,
      replyToId: replyToId,
    );
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
      sendFile: _controller.sendFile,
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
      sendFile: _controller.sendFile,
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
        sendFile: _controller.sendFile,
      );
    } catch (e) {
      if (mounted) {
        showPrysmToast(context, 'Could not read dropped file: $e');
      }
    }
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
    } else {
      showPrysmToast(context, context.l10n.messageNotFoundInLoadedHistory);
    }
  }

  @override
  void dispose() {
    _teardown();
    _typingTracker.dispose();
    _highlightTimer?.cancel();
    _swipeDragOffset.dispose();
    _listScrollController.removeListener(_onListScrollForward);
    _listScrollController.dispose();
    super.dispose();
  }

  String _deliveryStatusLabel(Message message) {
    if (message.metadata?['failed'] == true) return context.l10n.failed;
    if (isOutboundPending(message)) return context.l10n.pending;
    if (_settings.sendReadReceipts && message.seenAt != null) return context.l10n.read;
    if (message.sentAt != null) return context.l10n.delivered;
    return context.l10n.pending;
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
                  highlightQuery:
                      _showChatSearch ? _chatHighlightQuery : null,
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
                        PrysmPageRoute(page: ViewOnceImageScreen(
                          imageBytes: bytes,
                          title: null,
                          closeColor: const Color(0xB3FFFFFF),
                        ),
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
        DisappearingTimerAvatar(
          name: widget.group.name,
          radius: 20,
          avatarBase64: widget.group.avatarBase64,
          timerSeconds: _disappearingTimerSeconds,
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
        PrysmIconButton(
          icon: PrysmIcons.search,
          onPressed: () => setState(() {
            _showChatSearch = !_showChatSearch;
            if (!_showChatSearch) _chatHighlightQuery = '';
          }),
        ),
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
      bottom: _showChatSearch
          ? ChatSearchBar(
              conversationId: widget.group.id,
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
                  controller: _messages,
                  scrollController: _listScrollController,
                  onLoadMore: _controller.loadMoreMessages,
                  showJumpToBottom: selectedMessageIds.isEmpty,
                  onStickToBottomChanged: _controller.setStickToBottomSilently,
                  itemBuilder: _buildGroupChatListItem,
                ),
              ),
              // Same keyboard-inset overflow as the 1:1 chat body: the
              // composer is a non-flex Column child laid out with unbounded
              // main-axis constraints, so constrain and scroll it instead of
              // overflowing.
              PrysmConstrainedComposer(
                maxHeight: constraints.maxHeight,
                composer: PrysmChatComposerColumn(
                  draftKey: _draftKey,
                  replyPreview: _controller.replyToMessage != null || _controller.replyDraft != null
                      ? _buildReplyPreview()
                      : null,
                  typingTypistNames: _controller.typingTypistNames(),
                  onSendText: _controller.handleSendText,
                  onSendImage: _handleSendImage,
                  onSendFile: _handleSendFile,
                  onSendVoice: _controller.sendVoice,
                  onScheduleText:
                      widget.detachedClient == null ? _scheduleText : null,
                  onTypingChanged: _controller.onComposerTypingChanged,
                ),
              ),
            ],
          ),
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
    if (message is TextMessage &&
        message.metadata?['systemNotice'] == 'disappearing_timer') {
      return _buildDisappearingTimerNoticeRow(message, index);
    }

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
      onToggleSelect: () => _controller.toggleMessageSelection(message.id),
      onReply: () => _controller.setReplyToMessage(message),
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

  Widget _buildDisappearingTimerNoticeRow(TextMessage message, int index) {
    final timerSeconds = message.metadata?['timerSeconds'] as int?;
    final actorId = message.metadata?['actorId'] as String? ?? message.authorId;
    final label = disappearingTimerNoticeLabel(
      timerSeconds: timerSeconds,
      actorId: actorId,
      localUserId: widget.userId,
      actorDisplayName: _senderNames[actorId],
    );
    final showDateHeader = shouldShowChatDateHeader(_messages.messages, index);
    final tokens = context.prysmStyle.tokens;
    return Column(
      children: [
        if (showDateHeader) PrysmDateHeader(date: message.createdAt!),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Center(
            child: Container(
              constraints: const BoxConstraints(maxWidth: 320),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: tokens.surfaceElevated,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(PrysmIcons.timer, size: 16, color: tokens.textSecondary),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      label,
                      textAlign: TextAlign.center,
                      style: context.prysmStyle.captionStyle.copyWith(
                        color: tokens.textSecondary,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
