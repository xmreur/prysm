import 'package:flutter/widgets.dart';
import 'package:prysm/ui/core/prysm_button.dart';
import 'package:prysm/ui/core/prysm_dialog.dart';
import 'package:prysm/ui/core/prysm_icons.dart';
import 'package:prysm/ui/core/prysm_app.dart';
import 'package:prysm/ui/core/prysm_list_row.dart';
import 'package:prysm/ui/core/prysm_text_field.dart';
import 'package:prysm/ui/core/prysm_toast.dart';
import 'package:prysm/ui/prysm_scaffold.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:prysm/models/chat/prysm_message.dart';
import 'package:prysm/ui/chat/prysm_chat_message_list.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:prysm/models/reply_preview_data.dart';
import 'package:prysm/services/message_draft_store.dart';
import 'package:prysm/services/block_service.dart';
import 'package:prysm/services/call/call_manager.dart';
import 'package:prysm/transport/transport_preference.dart';
import 'package:prysm/transport/transport_provider.dart';
import 'package:prysm/util/peer_ws_connection_notifier.dart';
import 'package:prysm/util/tor_runtime_gate.dart';
import 'package:prysm/database/message_reactions.dart';
import 'package:prysm/database/messages.dart';
import 'package:prysm/screens/chat_profile_screen.dart';
import 'package:prysm/ui/chat/prysm_bubble_renderer.dart';
import 'package:prysm/ui/chat/prysm_chat_composer_column.dart';
import 'package:prysm/ui/chat/prysm_chat_list.dart';
import 'package:prysm/ui/chat/prysm_date_header.dart';
import 'package:prysm/ui/chat/prysm_message_row.dart';
import 'package:prysm/theme/prysm_style_scope.dart';
import 'package:prysm/theme/prysm_theme.dart';
import 'package:prysm/util/chat_scroll.dart';
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
import 'package:prysm/screens/widgets/quoted_reply_preview.dart';
import 'package:prysm/screens/widgets/quoted_reply_preview_loader.dart';
import 'package:prysm/util/reply_preview_label.dart';
import 'package:prysm/constants/media_constants.dart';
import 'package:prysm/services/file_attachment_resolver.dart';
import 'package:prysm/services/image_attachment_cache.dart';
import 'package:prysm/screens/widgets/deleted_message_bubble.dart';
import 'package:prysm/services/message_modify_service.dart';
import 'package:prysm/services/reaction_service.dart';
import 'package:prysm/services/read_receipt_service.dart';
import 'package:prysm/services/peer_presence_tracker.dart';
import 'package:prysm/services/settings_service.dart';
import 'package:prysm/database/message_read_receipts.dart';
import 'package:prysm/screens/widgets/message_status_icon.dart';
import 'package:prysm/screens/widgets/read_receipt_details_sheet.dart';
import 'package:prysm/util/message_status_mapper.dart';
import 'package:prysm/util/pending_message_db_helper.dart';
import 'package:prysm/util/outbound_read_status_refresh.dart';
import 'package:prysm/util/read_receipt_refresh_notifier.dart';
import 'package:prysm/util/message_content_wiper.dart';
import 'package:prysm/util/message_modify_policy.dart';
import 'package:prysm/util/message_modify_refresh_notifier.dart';
import 'package:prysm/util/notification_service.dart';
import 'package:prysm/util/reaction_refresh_notifier.dart';
import 'package:prysm/util/waveform_extractor.dart';
import 'package:prysm/services/battery_saver_service.dart';
import 'package:prysm/services/detached_chat_client.dart';
import 'package:prysm/services/chat_service.dart';
import 'package:prysm/services/conversation_preferences_service.dart';
import 'package:prysm/services/typing_indicator_service.dart';
import 'package:prysm/services/typing_state_tracker.dart';
import 'package:prysm/util/typing_indicator_notifier.dart';
import 'package:prysm/util/battery_saver_policy.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/crypto/wire.dart';
import 'package:prysm/util/tor_service.dart';
import 'package:prysm/util/group_crypto.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:prysm/models/contact.dart';

import 'package:uuid/uuid.dart';

class ChatScreen extends StatefulWidget {
  final String userId;
  final String userName;
  final String peerId;
  final String peerName;
  final String? peerAvatarBase64;
  final TorManager torManager;
  final KeyManager keyManager;
  final String? peerPublicKeyPem;
  final int currentTheme;
  final Function() clearChat;
  final Function() reloadUsers;

  final Function()? onCloseChat;
  final Widget? torStatusAction;
  final DetachedChatClient? detachedClient;

  const ChatScreen({
    required this.userId,
    required this.userName,
    required this.peerId,
    required this.peerName,
    this.peerAvatarBase64,
    required this.torManager,
    required this.keyManager,
    this.peerPublicKeyPem,
    this.currentTheme = 0,
    required this.clearChat,
    required this.reloadUsers,
    this.onCloseChat,
    this.torStatusAction,
    this.detachedClient,
    super.key,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  // ✅ ADD ChatService
  late ChatService _chatService;
  late ReactionService _reactionService;
  late ReadReceiptService _readReceiptService;
  final _settings = SettingsService();

  var _messages = InMemoryChatController();
  final Map<String, Message> _messageCache = {};
  
  bool _loading = false;
  bool _hasMore = true;
  int? _oldestTimestamp;
  String? _oldestMessageId;

  String _peerName = '';
  String? _peerAvatarBase64;
  // ignore: unused_field
  int _currentTheme = 0;
  bool? _peerOnline;
  late PeerPresenceTracker _presenceTracker;
  Timer? _presenceStaleTimer;
  StreamSubscription<PeerWsConnectionEvent>? _wsPresenceSub;
  StreamSubscription<void>? _batterySaverSub;

  Set<String> selectedMessageIds = {};
  Message? _replyToMessage;
  ReplyPreviewData? _replyDraft;
  final ValueNotifier<double> _swipeDragOffset = ValueNotifier(0);
  String? _swipeDragMessageId;

  final ScrollController _listScrollController = ScrollController();
  bool _stickToBottom = true;
  Timer? _debounceTimer;

  // ✅ ADD ChatService subscriptions
  StreamSubscription? _newMessagesSub;
  StreamSubscription? _statusSub;
  StreamSubscription? _reachableSub;
  StreamSubscription? _reactionSub;
  StreamSubscription? _reactionRefreshSub;
  StreamSubscription? _modifyRefreshSub;
  StreamSubscription? _detachedInboundSub;
  StreamSubscription? _detachedStatusSub;
  StreamSubscription? _readReceiptRefreshSub;
  Timer? _readReceiptDebounce;
  late MessageModifyService _modifyService;
  String? _highlightedMessageId;
  Timer? _highlightTimer;
  late TypingIndicatorService _typingService;
  final _typingTracker = TypingStateTracker();
  StreamSubscription<TypingIndicatorEvent>? _typingSub;
  StreamSubscription<void>? _typingTrackerSub;

  void _onListScroll() {
    final atBottom = isChatScrolledToBottom(_listScrollController);
    if (atBottom == _stickToBottom) return;
    setState(() => _stickToBottom = atBottom);
  }

  String get _draftKey => 'dm:${widget.peerId}';

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

  @override
  void initState() {
    super.initState();
    _currentTheme = widget.currentTheme;
    _peerName = widget.peerName;
    _peerAvatarBase64 = widget.peerAvatarBase64;
    

    // ✅ INITIALIZE ChatService
    _chatService = ChatService(
      userId: widget.userId,
      peerId: widget.peerId,
      keyManager: widget.keyManager,
    );
    _reactionService = ReactionService.direct(
      userId: widget.userId,
      keyManager: widget.keyManager,
      peerId: widget.peerId,
    );
    _readReceiptService = ReadReceiptService.direct(
      userId: widget.userId,
      keyManager: widget.keyManager,
      peerId: widget.peerId,
    );
    _modifyService = MessageModifyService.direct(
      userId: widget.userId,
      keyManager: widget.keyManager,
      peerId: widget.peerId,
    );
    _typingService = TypingIndicatorService.direct(
      userId: widget.userId,
      peerId: widget.peerId,
      settings: _settings,
    );
    _setupTypingSubscriptions();

    _presenceTracker = PeerPresenceTracker();
    _listScrollController.addListener(_onListScroll);
    _initializeChat();
    _initPeerPresence();
    _setupDetachedClientSubscriptions();
    _batterySaverSub = BatterySaverService.instance.onChanged.listen((_) {
      if (mounted) {
        _startPresenceStaleTimer();
      }
    });
  }

  bool get _isNetworkAvailable =>
      TransportProvider.isConfigured && !TorRuntimeGate.blocked;

  void _applyOfflinePresence() {
    if (!mounted) return;
    if (_peerOnline != false) {
      setState(() => _peerOnline = false);
    }
  }

  void _initPeerPresence() {
    if (_isPeerBlocked) return;
    if (!_isNetworkAvailable) {
      _applyOfflinePresence();
    } else {
      _syncPeerPresenceFromWs();
      _subscribeToWsPresence();
      unawaited(_refreshPeerProfile());
    }
    _startPresenceStaleTimer();
  }

  void _syncPeerPresenceFromWs() {
    if (!_isNetworkAvailable) {
      _applyOfflinePresence();
      return;
    }
    final manager = TransportProvider.instance.wsManager;
    if (manager.isConnected(widget.peerId)) {
      _presenceTracker.recordWsConnected();
    } else if (manager.isConnectInFlight(widget.peerId)) {
      _presenceTracker.clearWsState();
    } else {
      _presenceTracker.recordWsDisconnected();
    }
    _syncPeerPresence();
  }

  void _subscribeToWsPresence() {
    _wsPresenceSub?.cancel();
    _wsPresenceSub = PeerWsConnectionNotifier.instance.onChanged.listen((event) {
      if (event.peerOnion != widget.peerId || !mounted) return;
      if (event.connected) {
        _presenceTracker.recordWsConnected();
        _syncPeerPresence();
        unawaited(_refreshPeerProfile());
      } else {
        _presenceTracker.recordWsDisconnected();
        _syncPeerPresence();
      }
    });
  }

  void _syncPeerPresence() {
    if (!mounted) return;
    final online = _presenceTracker.isOnline;
    if (online != _peerOnline) {
      setState(() => _peerOnline = online);
    }
  }

  void _recordPeerActivity() {
    _presenceTracker.recordActivity();
    _syncPeerPresence();
  }

  void _startPresenceStaleTimer() {
    _presenceStaleTimer?.cancel();
    _presenceStaleTimer = Timer.periodic(
      BatterySaverPolicy.presenceStaleCheckInterval(),
      (_) {
        if (!mounted) return;
        if (_isNetworkAvailable) {
          _syncPeerPresenceFromWs();
        } else {
          _applyOfflinePresence();
        }
      },
    );
  }

  // ✅ NEW: Initialize ChatService
  Future<void> _initializeChat() async {
    final success = await _chatService.initialize(widget.peerPublicKeyPem);

    if (!success && mounted) {
      showPrysmToast(
        context,
        'Could not connect to peer. Messages will be queued.',
      );
    }

    // ✅ Listen to ChatService streams (main window only)
    if (widget.detachedClient == null) {
      _newMessagesSub = _chatService.onNewMessages.listen(_handleNewMessages);
      _statusSub = _chatService.onMessageStatus.listen(_handleStatusUpdate);
      _reachableSub = _chatService.onPeerReachable.listen((_) {
        if (mounted) _recordPeerActivity();
      });
    }
    _reactionSub = _reactionService.onReactionsChanged.listen(_applyReactionUpdate);
    _reactionRefreshSub =
        ReactionRefreshNotifier.instance.onReactionChanged.listen(_applyReactionUpdate);
    _modifyRefreshSub = MessageModifyRefreshNotifier.instance.onModifyChanged
        .listen(_applyModifyUpdate);
    _readReceiptRefreshSub =
        ReadReceiptRefreshNotifier.instance.onReadReceiptChanged
            .listen(_applyReadReceiptUpdate);

    await _loadInitialMessages();
    _restoreReplyDraft();
    await _markInboundAsRead();

    if (mounted && _messages.messages.isNotEmpty) {
      _stickToBottom = true;
      scheduleScrollChatToBottom(_messages, isMounted: () => mounted);
    }

    // ✅ Start ChatService background tasks (main window only)
    if (widget.detachedClient == null) {
      _chatService.startPolling();
      _chatService.startSendQueue();
      if (TransportProvider.isConfigured) {
        TransportProvider.instance.pinPeer(widget.peerId);
      }
    }
  }

  void _onTypingEvent(TypingIndicatorEvent event) {
    if (event.groupId != null) return;
    if (event.senderId != widget.peerId) return;

    _typingTracker.applyEvent(
      conversationKey: widget.peerId,
      senderId: event.senderId,
      typing: event.typing,
      timestamp: event.timestamp,
    );
  }

  List<String> _typingTypistNames() {
    if (!_settings.enableTypingIndicators) return const [];
    return _typingTracker
        .activeTypists(widget.peerId)
        .map((id) => _peerName.isNotEmpty ? _peerName : id)
        .toList(growable: false);
  }

  void _onComposerTypingChanged(bool isTyping) {
    _typingService.onComposerTypingChanged(isTyping);
  }

  // ✅ NEW: Handle incoming messages from ChatService
  void _handleNewMessages(List<Map<String, dynamic>> rawMessages) async {
    if (!mounted) return;

    if (rawMessages.any((msg) => msg['senderId'] == widget.peerId)) {
      _recordPeerActivity();
    }

    try {
      final decrypted = await _decryptForDisplay(rawMessages);
      if (!mounted) return;

      setState(() {
        final existingIds = _messages.messages.map((m) => m.id).toSet();
        for (final msg in decrypted) {
          if (!existingIds.contains(msg.id)) {
            _messages.insertMessage(msg, index: _messages.messages.length);
          }
        }
      });
      _scheduleScrollToBottomIfNeeded();
      await _markInboundAsRead();
    } catch (e) {
      debugPrint('Error handling new messages: $e');
    }
  }

  // ✅ NEW: Handle message status updates
  void _handleStatusUpdate(MessageStatusUpdate update) {
    if (!mounted) return;

    if (update.status == 'sent') {
      _recordPeerActivity();
    }

    final idx = _messages.messages.indexWhere((m) => m.id == update.messageId);
    if (idx != -1) {
      setState(() {
        final msg = _messages.messages[idx];
        final updated = messageWithDeliveryUpdate(
          msg,
          status: update.status,
          readReceiptsEnabled: _settings.sendReadReceipts,
        );
        _messages.updateMessage(msg, updated);
        _messageCache[msg.id] = updated;
      });
    }
  }

  Future<void> _markInboundAsRead() async {
    final waterline = await MessagesDb.markInboundConversationRead(
      widget.userId,
      widget.peerId,
    );
    if (waterline == null) return;

    unawaited(
      NotificationService().cancelConversationNotificationIfForeground(
        senderId: widget.peerId,
      ),
    );

    _readReceiptDebounce?.cancel();
    _readReceiptDebounce = Timer(const Duration(milliseconds: 100), () async {
      if (!mounted) return;
      if (_settings.sendReadReceipts) {
        await _readReceiptService.sendWaterline(waterline);
      }
    });
  }

  Future<void> _applyReadReceiptUpdate(ReadReceiptUpdate update) async {
    if (!mounted || !_settings.sendReadReceipts) return;
    if (update.groupId != null) return;

    final refreshed = await refreshOutboundReadStatus(
      messages: _messages.messages,
      localUserId: widget.userId,
      readReceiptsEnabled: _settings.sendReadReceipts,
      requiredReadCount: 1,
    );
    if (!mounted) return;

    var anyNewlyRead = false;
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
          if (updated.seenAt != null && old.seenAt == null) {
            anyNewlyRead = true;
          }
          _messages.updateMessage(old, updated);
          _messageCache[updated.id] = updated;
        } catch (_) {}
      }
    });

    if (anyNewlyRead) _recordPeerActivity();
  }

  void _cancelChatSubscriptions() {
    _newMessagesSub?.cancel();
    _newMessagesSub = null;
    _statusSub?.cancel();
    _statusSub = null;
    _reachableSub?.cancel();
    _reachableSub = null;
    _reactionSub?.cancel();
    _reactionSub = null;
    _reactionRefreshSub?.cancel();
    _reactionRefreshSub = null;
    _modifyRefreshSub?.cancel();
    _modifyRefreshSub = null;
    _detachedInboundSub?.cancel();
    _detachedInboundSub = null;
    _detachedStatusSub?.cancel();
    _detachedStatusSub = null;
    _readReceiptRefreshSub?.cancel();
    _readReceiptRefreshSub = null;
    _typingSub?.cancel();
    _typingSub = null;
    _typingTrackerSub?.cancel();
    _typingTrackerSub = null;
    _wsPresenceSub?.cancel();
    _wsPresenceSub = null;
    _batterySaverSub?.cancel();
    _batterySaverSub = null;
    _readReceiptDebounce?.cancel();
    _readReceiptDebounce = null;
    _presenceStaleTimer?.cancel();
    _presenceStaleTimer = null;
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _highlightTimer?.cancel();
    _highlightTimer = null;
  }

  void _setupDetachedClientSubscriptions() {
    final client = widget.detachedClient;
    if (client == null) return;
    _detachedInboundSub = client.onInboundMessages.listen((messages) {
      if (!mounted) return;
      setState(() {
        final existingIds = _messages.messages.map((m) => m.id).toSet();
        for (final msg in messages) {
          if (!existingIds.contains(msg.id)) {
            _messages.insertMessage(msg, index: _messages.messages.length);
          }
        }
      });
      _scheduleScrollToBottomIfNeeded();
    });
    _detachedStatusSub = client.onStatusUpdates.listen((update) {
      _handleStatusUpdate(
        MessageStatusUpdate(
          update['messageId'] as String,
          update['status'] as String,
        ),
      );
    });
  }

  void _setupTypingSubscriptions() {
    _typingSub =
        TypingIndicatorNotifier.instance.events.listen(_onTypingEvent);
    _typingTrackerSub = _typingTracker.onChanged.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _typingService.dispose();
    _typingTracker.dispose();
    _chatService.dispose();
    _reactionService.dispose();
    _cancelChatSubscriptions();
    _swipeDragOffset.dispose();
    _listScrollController.removeListener(_onListScroll);
    _listScrollController.dispose();
    if (TransportProvider.isConfigured) {
      TransportProvider.instance.unpinPeer(widget.peerId);
    }
    super.dispose();
  }

  /// Fetches fresh name/avatar from /profile.
  Future<void> _refreshPeerProfile({
    TransportPreference preference = TransportPreference.wsPreferred,
  }) async {
    if (_isPeerBlocked) return;
    if (!_isNetworkAvailable) return;
    try {
      final body = await TransportProvider.getProfileOrFallback(
        widget.peerId,
        preference: preference,
      );
      final data = jsonDecode(body) as Map<String, dynamic>;

      if (!mounted) return;

      // Update DB with fresh remote data
      final updates = <String, dynamic>{};
      if (data['publicKeyPem'] != null && (data['publicKeyPem'] as String).isNotEmpty) {
        updates['publicKeyPem'] = data['publicKeyPem'];
      }
      if (data['username'] != null && (data['username'] as String).isNotEmpty) {
        updates['name'] = data['username'];
      }
      if (data['avatar'] != null && (data['avatar'] as String).isNotEmpty) {
        updates['avatarBase64'] = data['avatar'];
      }
      if (updates.isNotEmpty) {
        await DBHelper.updateUserFields(widget.peerId, updates);
      }

      // Read back from DB to respect customName
      final userData = await DBHelper.getUserById(widget.peerId);
      if (userData != null && mounted) {
        final customName = userData['customName'] as String?;
        final remoteName = userData['name'] as String? ?? _peerName;
        final newName = (customName != null && customName.isNotEmpty) ? customName : remoteName;
        final newAvatar = userData['avatarBase64'] as String?;
        final changed = newName != _peerName || newAvatar != _peerAvatarBase64;
        if (changed) {
          setState(() {
            _peerName = newName;
            _peerAvatarBase64 = newAvatar;
          });
          widget.reloadUsers(); // Refresh sidebar with updated name/avatar
        }
      }
    } catch (e) {
      debugPrint('Profile refresh failed: $e');
    }
  }

  void resetChatState() {
    _messages = InMemoryChatController();
    _replyToMessage = null;
    _replyDraft = null;
    _messageCache.clear();
    _oldestTimestamp = null;
    _oldestMessageId = null;
    _hasMore = true;
    _loading = false;
    selectedMessageIds.clear();
  }

  @override
  void didUpdateWidget(covariant ChatScreen oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.peerId != widget.peerId) {
      if (TransportProvider.isConfigured) {
        TransportProvider.instance.unpinPeer(oldWidget.peerId);
      }
      _cancelChatSubscriptions();
      _chatService.dispose();
      _reactionService.dispose();
      _typingService.dispose();
      _typingTracker.clearConversation(oldWidget.peerId);

      _presenceTracker = PeerPresenceTracker();
      if (mounted) {
        setState(() {
          resetChatState();
          _peerName = widget.peerName;
          _peerAvatarBase64 = widget.peerAvatarBase64;
          _peerOnline = null;
        });
      }

      _chatService = ChatService(
        userId: widget.userId,
        peerId: widget.peerId,
        keyManager: widget.keyManager,
      );
      _reactionService = ReactionService.direct(
        userId: widget.userId,
        keyManager: widget.keyManager,
        peerId: widget.peerId,
      );
      _readReceiptService = ReadReceiptService.direct(
        userId: widget.userId,
        keyManager: widget.keyManager,
        peerId: widget.peerId,
      );
      _modifyService = MessageModifyService.direct(
        userId: widget.userId,
        keyManager: widget.keyManager,
        peerId: widget.peerId,
      );
      _typingService = TypingIndicatorService.direct(
        userId: widget.userId,
        peerId: widget.peerId,
        settings: _settings,
      );
      _setupTypingSubscriptions();
      _setupDetachedClientSubscriptions();
      _batterySaverSub = BatterySaverService.instance.onChanged.listen((_) {
        if (mounted) {
          _startPresenceStaleTimer();
        }
      });

      _initializeChat();
      _initPeerPresence();
    }

    if (oldWidget.currentTheme != widget.currentTheme) {
      setState(() => _currentTheme = widget.currentTheme);
    }
    if (oldWidget.peerName != widget.peerName) {
      setState(() => _peerName = widget.peerName);
    }
    if (oldWidget.peerAvatarBase64 != widget.peerAvatarBase64) {
      setState(() => _peerAvatarBase64 = widget.peerAvatarBase64);
    }
  }

  // ==================== DECRYPTION (KEEP AS-IS) ====================

  Future<String> _decryptDirectTextMessage(
    Map<String, dynamic> msg,
    KeyManager keyManager,
  ) async {
    final senderId = msg['senderId'] as String;
    final wire = msg['message'] as String?;
    if (wire == null || wire.isEmpty) {
      throw const FormatException('Empty message payload');
    }

    final trimmed = wire.trimLeft();
    if (trimmed.startsWith('{')) {
      final parsed = jsonDecode(wire);
      if (parsed is Map<String, dynamic>) {
        if (parsed['envelope'] == GroupCrypto.controlEnvelopeVersion) {
          throw const FormatException('Misrouted group control payload');
        }
        if (parsed.containsKey('iv') && parsed.containsKey('ct')) {
          throw const FormatException('Group-encoded payload in direct chat');
        }
      }
    }

    if (senderId == widget.userId) {
      return await keyManager.decryptMessage(wire);
    }

    final user = await DBHelper.getUserById(senderId);
    final identityJson = (user?['identityJson'] as String?) ??
        (user?['publicKeyPem'] as String?);
    if (identityJson == null || identityJson.isEmpty) {
      throw const FormatException('Missing peer identity');
    }
    final peerKey = keyManager.importPeerIdentity(identityJson);
    return keyManager.decryptPeerMessage(
      peerId: senderId,
      wire: wire,
      peer: peerKey,
    );
  }

  Future<List<Message>> decryptMessagesDeferred(
    List<Map<String, dynamic>> rawMessages,
    KeyManager keyManager,
  ) async {
    List<Message> messages = [];

    for (var msg in rawMessages) {
      if (_messageCache.containsKey(msg['id'])) {
        messages.add(_messageCache[msg['id']]!);
        continue;
      }
      final meta = metadataFromDbRow(msg);
      final wire = msg['message'];
      if (meta['deleted'] == true || wire == null || (wire is String && wire.isEmpty)) {
        messages.add(_deletedMessageFromRow(msg, {
          ...meta,
          'deleted': true,
        }));
        continue;
      }
      try {
        if (msg['type'] == 'text') {
          messages.add(
            TextMessage(
              authorId: msg['senderId'] as String,
              createdAt: DateTime.fromMillisecondsSinceEpoch(msg['timestamp']),
              id: msg['id'],
              replyToMessageId: msg['replyTo'],
              text: await _decryptDirectTextMessage(msg, keyManager),
              metadata: meta.isEmpty ? null : meta,
            ),
          );
        } else if (msg['type'] == 'file') {
          final fileName = msg['fileName'] ?? 'Unknown';
          final msgId = msg['id'] as String;
          messages.add(
            FileMessage(
              id: msgId,
              authorId: msg['senderId'] as String,
              createdAt: DateTime.fromMillisecondsSinceEpoch(msg['timestamp']),
              replyToMessageId: msg['replyTo'],
              name: fileName,
              size: msg['fileSize'] ?? 0,
              source: msg['message'],
            ),
          );
        } else if (msg['type'] == 'audio') {
          messages.add(
            FileMessage(
              id: msg['id'],
              authorId: msg['senderId'] as String,
              createdAt: DateTime.fromMillisecondsSinceEpoch(msg['timestamp']),
              replyToMessageId: msg['replyTo'],
              name: msg['fileName'] ?? 'voice_message.wav',
              size: msg['fileSize'] ?? 0,
              source: msg['message'],
            ),
          );
        } else if (msg['type'] == 'call') {
          final payload = jsonDecode((msg['message'] as String?) ?? '{}')
              as Map<String, dynamic>;
          messages.add(
            PrysmCallMessage(
              id: msg['id'],
              authorId: msg['senderId'] as String,
              createdAt: DateTime.fromMillisecondsSinceEpoch(msg['timestamp']),
              durationMs: (payload['durationMs'] as num?)?.toInt() ?? 0,
              callStatus: payload['status'] as String? ?? 'completed',
              direction: payload['direction'] as String? ?? 'outbound',
            ),
          );
        } else if (msg['type'] == "image") {
          final isViewOnce = (msg['viewOnce'] ?? 0) == 1;
          final isViewed = (msg['viewed'] ?? 0) == 1;

          if (isViewOnce && isViewed) {
            // View-once already opened — show placeholder
            messages.add(
              ImageMessage(
                id: msg['id'],
                authorId: msg['senderId'] as String,
                createdAt: DateTime.fromMillisecondsSinceEpoch(msg['timestamp']),
                replyToMessageId: msg['replyTo'],
                size: 0,
                source: "",
                metadata: {'viewOnce': true, 'viewed': true},
              ),
            );
          } else {
            final msgId = msg['id'] as String;
            messages.add(
              ImageMessage(
                id: msgId,
                authorId: msg['senderId'] as String,
                createdAt: DateTime.fromMillisecondsSinceEpoch(msg['timestamp']),
                replyToMessageId: msg['replyTo'],
                size: msg['fileSize'] ?? 0,
                source: isViewOnce
                    ? ''
                    : deferredImageSourceFor(msgId),
                metadata: isViewOnce
                    ? {'viewOnce': true, 'viewed': false}
                    : (meta.isEmpty ? null : meta),
              ),
            );
          }
        }
      } catch (e) {
        debugPrint('Direct message decrypt failed (${msg['id']}): $e');
        messages.add(
          TextMessage(
            authorId: msg['senderId'] as String,
            createdAt: DateTime.fromMillisecondsSinceEpoch(msg['timestamp']),
            id: msg['id'],
            replyToMessageId: msg['replyTo'],
            text: '🔒 Unable to decrypt message',
          ),
        );
      }
    }
    final withReactions = await _attachReactions(messages);
    return _attachOutboundStatus(withReactions, rawMessages);
  }

  Future<List<Message>> _attachReactions(List<Message> messages) async {
    if (messages.isEmpty) return messages;
    final ids = messages.map((m) => m.id).toList();
    final reactions = await _reactionService.loadReactionsForMessages(ids);
    return messages
        .map((m) => applyReactionsToMessage(m, reactions[m.id]))
        .toList();
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

    final receipts =
        await MessageReadReceiptsDb.getReceiptsForMessages(outboundWireIds);

    return messages.map((m) {
      final row = rowByWireId[m.id];
      if (row == null) return m;
      final status = outboundStatusFromDbRow(
        row: row,
        localUserId: widget.userId,
        readReceiptsEnabled: readReceiptsEnabled,
        receipts: receipts[m.id] ?? const [],
        requiredReadCount: 1,
      );
      return applyOutboundStatus(m, status: status);
    }).toList();
  }

  Message _deletedMessageFromRow(
    Map<String, dynamic> msg,
    Map<String, Object?> meta,
  ) {
    return TextMessage(
      authorId: msg['senderId'] as String,
      createdAt: DateTime.fromMillisecondsSinceEpoch(msg['timestamp'] as int),
      id: msg['id'] as String,
      replyToMessageId: msg['replyTo'] as String?,
      text: '',
      metadata: meta,
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
        _messageCache[msg.id] = updated;
      });
    } catch (_) {}
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
        _messageCache[msg.id] = updated;
      });
    } catch (_) {}
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
      final updated = message.copyWith(
        text: editedText,
        metadata: {...?message.metadata, 'edited': true},
      );
      setState(() {
        _messages.updateMessage(message, updated);
        _messageCache[message.id] = updated;
      });
    } else {
      showPrysmToast(context, 'Could not edit message');
    }
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

  Widget _replyQuoteFor(Message message, bool isSentByMe) {
    return QuotedReplyPreviewLoader(
      replyToMessageId: message.replyToMessageId,
      messages: _messages.messages,
      isSentByMe: isSentByMe,
      onTap: (id) => unawaited(_scrollToMessage(id)),
    );
  }

  Widget _wrapWithReplyQuote(
    Message message,
    bool isSentByMe,
    Widget child,
  ) {
    return Column(
      crossAxisAlignment:
          isSentByMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _replyQuoteFor(message, isSentByMe),
        child,
      ],
    );
  }

  Future<void> _onReactionSelected(Message message, String emoji) async {
    await _reactionService.toggleReaction(
      targetMessageId: message.id,
      emoji: emoji,
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
      onReactionTap: (emoji) => _onReactionSelected(message, emoji),
    );
  }

  Future<Uint8List> decryptFileInBackground(
    Map<String, dynamic> msg,
    KeyManager keyManager,
  ) async {
    if (widget.detachedClient != null) {
      final messages = await widget.detachedClient!.decryptRows([msg]);
      if (messages.isEmpty) {
        throw StateError('Failed to decrypt file');
      }
      final decrypted = messages.first;
      if (decrypted is FileMessage) {
        if (decrypted.source.startsWith('audio:')) {
          final parts = decrypted.source.split(':');
          if (parts.length >= 3) {
            return File(parts[2]).readAsBytes();
          }
        }
        return base64Decode(decrypted.source);
      }
      throw StateError('Unexpected decrypted type for file');
    }
    return FileAttachmentResolver.decryptEncryptedSource(
      msg['message'] as String,
      keyManager,
    );
  }

  Future<Uint8List> _decryptImageFromDb(String messageId) async {
    final rows = await MessagesDb.getMessageById(messageId);
    if (rows.isEmpty) {
      throw StateError('Image message not found: $messageId');
    }
    if (widget.detachedClient != null) {
      final messages = await widget.detachedClient!.decryptRows(rows);
      if (messages.isEmpty) {
        throw StateError('Failed to decrypt image: $messageId');
      }
      final msg = messages.first;
      if (msg is ImageMessage && msg.source.isNotEmpty) {
        if (msg.source.startsWith('data:')) {
          final comma = msg.source.indexOf(',');
          if (comma >= 0) {
            return base64Decode(msg.source.substring(comma + 1));
          }
        }
        return base64Decode(msg.source);
      }
      if (msg is FileMessage && msg.source.isNotEmpty) {
        return base64Decode(msg.source);
      }
      throw StateError('Unexpected decrypted type for image: $messageId');
    }
    final row = rows.first;
    final wire = row['message'] as String?;
    if (wire == null || wire.isEmpty) {
      throw StateError('Empty image payload: $messageId');
    }
    return decryptFileInBackground(row, widget.keyManager);
  }

  String _mimeTypeForImageBytes(Uint8List bytes) {
    return ImageAttachmentCache.sniffImageMimeType(bytes);
  }

  Future<List<Message>> _decryptForDisplay(
    List<Map<String, dynamic>> rawMessages,
  ) async {
    if (widget.detachedClient != null) {
      return widget.detachedClient!.decryptRows(rawMessages);
    }
    return decryptMessagesDeferred(rawMessages, widget.keyManager);
  }

  // ==================== MESSAGE LOADING (KEEP AS-IS) ====================

  Future<void> _loadInitialMessages() async {
    await _loadMoreMessages();
  }

  Future<void> _loadMoreMessages() async {
    if (_loading || !_hasMore) return;
    _loading = true;

    final batch = await MessagesDb.getMessagesBetweenBatchWithId(
      widget.userId,
      widget.peerId,
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

    final modifiableList = List.of(batch);
    modifiableList.sort(
      (a, b) => (a['timestamp'] as int).compareTo(b['timestamp'] as int),
    );

    final newMessages = await _decryptForDisplay(modifiableList);

    if (!mounted) return;

    if (modifiableList.isNotEmpty) {
      final newestTs = modifiableList
          .map((m) => m['timestamp'] as int)
          .reduce(max);
      _chatService.seedNewestTimestamp(newestTs);
    }

    setState(() {
      _messages.insertAllMessages(newMessages, index: 0);
      _oldestTimestamp = batch.last['timestamp'];
      _oldestMessageId = batch.last['id'];
      _loading = false;
    });
  }

  // ==================== MESSAGE SENDING ====================

  void _handleSendText(String text) async {
    if (!mounted) return;

    var replyToId = _replyToMessageId;

    // ✅ Generate ID and show UI IMMEDIATELY
    final messageId = const Uuid().v4();

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

    // ✅ NOW send in background (non-blocking)
    if (widget.detachedClient != null) {
      widget.detachedClient!
          .sendText(
            text: text,
            replyToId: replyToId,
            messageId: messageId,
          )
          .then((sentId) {
            if (sentId == null && mounted) {
              showPrysmToast(context, 
                    'Message queued. Will send when peer is available.',
                  );
            }
          });
      return;
    }
    _chatService
        .sendTextMessage(text, replyToId: replyToId, messageId: messageId)
        .then((sentId) {
          if (sentId == null && mounted) {
            showPrysmToast(context, 
                  'Message queued. Will send when peer is available.',
                );
          }
        });
  }

  Future<void> _sendFile(Uint8List bytes, String fileName, String type, {bool viewOnce = false}) async {
    if (!mounted) return;

    var replyToId = _replyToMessageId;

    // ✅ Generate ID and show UI IMMEDIATELY
    final messageId = const Uuid().v4();

    setState(() {
      if (type == "file") {
        _messages.insertMessage(
          messageWithPendingStatus(
            FileMessage(
              authorId: widget.userId,
              createdAt: DateTime.now(),
              id: messageId,
              name: fileName,
              size: bytes.length,
              replyToMessageId: replyToId,
              source: base64Encode(bytes),
            ),
          ),
          index: _messages.messages.length,
        );
      } else if (type == "image") {
        _messages.insertMessage(
          messageWithPendingStatus(
            ImageMessage(
              authorId: widget.userId,
              createdAt: DateTime.now(),
              id: messageId,
              size: bytes.length,
              replyToMessageId: replyToId,
              source:
                  "data:${_mimeTypeForImageBytes(bytes)};base64,${base64Encode(bytes)}",
              metadata: viewOnce ? {'viewOnce': true, 'viewed': false} : null,
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

    // ✅ NOW send in background
    if (widget.detachedClient != null) {
      widget.detachedClient!
          .sendFile(
            bytes: bytes,
            fileName: fileName,
            type: type,
            replyToId: replyToId,
            messageId: messageId,
            viewOnce: viewOnce,
          )
          .then((sentId) {
            if (sentId == null && mounted) {
              showPrysmToast(context, 'File queued. Will send when peer is available.');
            }
          });
      return;
    }
    _chatService
        .sendFileMessage(
          bytes,
          fileName,
          type,
          replyToId: replyToId,
          messageId: messageId,
          viewOnce: viewOnce,
        )
        .then((sentId) {
          if (sentId == null && mounted) {
            showPrysmToast(context, 'File queued. Will send when peer is available.');
          }
        });
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
    final replyToId = _replyToMessageId;

    // Save to cache so we can play back our own sent voice messages
    final cacheDir = await getTemporaryDirectory();
    final cachePath = '${cacheDir.path}/voice_cache_$messageId.wav';
    await File(cachePath).writeAsBytes(bytes);
    final peaks = WaveformExtractor.extractPeaks(bytes);
    final waveformMeta = WaveformExtractor.encodePeaks(peaks);

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
            metadata: {'waveform': waveformMeta},
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
      widget.detachedClient!
          .sendVoice(
            bytes: bytes,
            durationMs: durationMs,
            messageId: messageId,
          )
          .then((sentId) {
            if (sentId == null && mounted) {
              showPrysmToast(context, 'Voice message queued. Will send when peer is available.');
            }
          });
      return;
    }

    _chatService
        .sendFileMessage(
          bytes,
          'voice_message.wav',
          'audio',
          messageId: messageId,
          replyToId: replyToId,
        )
        .then((sentId) {
          if (sentId == null && mounted) {
            showPrysmToast(context, 'Voice message queued. Will send when peer is available.');
          }
        });
  }

  // ==================== UI HELPERS (KEEP AS-IS) ====================

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

  bool get _isPeerBlocked => BlockService.instance.isBlocked(widget.peerId);

  bool get _canStartCall {
    if (_isPeerBlocked) return false;
    if (TorRuntimeGate.blocked) return false;
    if (!TransportProvider.isConfigured) return false;
    if (!TransportProvider.instance.isRealtimeConnected(widget.peerId)) {
      return false;
    }
    try {
      return !CallManager.instance.snapshot.isInCall;
    } catch (_) {
      return false;
    }
  }

  Future<void> _startAudioCall() async {
    try {
      await CallManager.instance.startCall(widget.peerId);
    } catch (e) {
      if (!mounted) return;
      showPrysmToast(context, 'Could not start call: $e');
    }
  }

  void _openChatProfile() async {
    final peerContact = Contact(
      id: widget.peerId,
      name: _peerName,
      avatarUrl: '',
      avatarBase64: _peerAvatarBase64,
      identityJson: widget.peerPublicKeyPem ?? '',
    );

    final result = await Navigator.push(
      context,
      PrysmPageRoute(page: ChatProfileScreen(
          peer: peerContact,
          currentUserName: widget.userName,
          isOnline: _peerOnline,
          userId: widget.userId,
          keyManager: widget.keyManager,
          onClose: () => Navigator.of(context).pop(),
          onUpdateName: (Contact updatedContact) async {
            // Save custom name to the customName column (not name)
            await DBHelper.updateUserFields(updatedContact.id, {
              'customName': updatedContact.customName,
            });
            widget.reloadUsers();
          },
          onDeleteChat: () async {
            await MessagesDb.deleteMessagesBetween(
              widget.userId,
              widget.peerId,
            );
            resetChatState();
            setState(() {
              _messages = InMemoryChatController();
            });
            MessageDraftStore.instance.setReply(_draftKey, null);
            _loadInitialMessages();
          },
          onDeleteContact: () async {
            await ConversationPreferencesService.instance.delete(widget.peerId);
            await DBHelper.deleteUser(widget.peerId);
            resetChatState();
            setState(() {
              _messages = InMemoryChatController();
            });
            MessageDraftStore.instance.setReply(_draftKey, null);
            widget.clearChat();
          },
          onPreferencesChanged: widget.reloadUsers,
          onArchived: () {
            Navigator.of(context).pop();
            widget.clearChat();
          },
          onBlocked: () {
            widget.reloadUsers();
            Navigator.of(context).pop();
            widget.clearChat();
          },
          onUnblocked: () {
            widget.reloadUsers();
            unawaited(_refreshPeerProfile());
            _initPeerPresence();
          },
        ),
      ),
    );

    if (result is Contact) {
      if (mounted) setState(() => _peerName = result.displayName);
    } else if (result is String) {
      await _scrollToMessage(result);
    }
  }

  Widget _buildReplyPreview() {
    final data = _replyToMessage != null
        ? replyPreviewFromMessage(_replyToMessage!)
        : _replyDraft;
    if (data == null) return const SizedBox.shrink();
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
              ),
            ),
            PrysmIconButton(
              icon: PrysmIcons.close,
              onPressed: () {
                setState(_clearReplyState);
              },
            ),
          ],
        ),
      ),
    );
  }

  String _getMessageText(Message message) {
    if (message is TextMessage) return message.text;
    if (message is FileMessage) return message.name;
    if (message is ImageMessage) return '📷 Image';
    if (message is PrysmCallMessage) return _callMessageLabel(message);
    return '';
  }

  String _callMessageLabel(PrysmCallMessage message) {
    final direction = message.direction == 'outbound' ? 'Outgoing' : 'Incoming';
    final status = _prettyCallStatus(message.callStatus);
    if (message.callStatus == 'completed') {
      final duration = _formatCallDuration(message.durationMs);
      return '$direction call · $duration';
    }
    return '$direction call · $status';
  }

  String _prettyCallStatus(String status) {
    switch (status) {
      case 'completed':
        return 'Completed';
      case 'missed':
        return 'Missed';
      case 'declined':
        return 'Declined';
      case 'failed':
        return 'Failed';
      default:
        return status;
    }
  }

  String _formatCallDuration(int durationMs) {
    final seconds = (durationMs ~/ 1000).clamp(0, Duration.secondsPerDay * 99);
    final minutes = seconds ~/ 60;
    final secs = seconds % 60;
    if (minutes > 0) {
      return '${minutes}m ${secs.toString().padLeft(2, '0')}s';
    }
    return '${secs}s';
  }

  Widget _callMessageBuilder(PrysmCallMessage message) {
    final tokens = context.prysmStyle.tokens;
    final isMissed = message.callStatus == 'missed';
    final label = _callMessageLabel(message);
    final timeString = message.createdAt != null
        ? '${message.createdAt!.hour.toString().padLeft(2, '0')}:${message.createdAt!.minute.toString().padLeft(2, '0')}'
        : '';

    return Center(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 280),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: tokens.surfaceElevated,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              PrysmIcons.phone,
              size: 16,
              color: isMissed ? tokens.danger : tokens.textSecondary,
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
              label,
              style: context.prysmStyle.captionStyle.copyWith(
                color: isMissed ? tokens.danger : tokens.textSecondary,
                fontWeight: FontWeight.w500,
              ),
            ),
            ),
            if (timeString.isNotEmpty) ...[
              const SizedBox(width: 8),
              Text(
                timeString,
                style: context.prysmStyle.captionStyle.copyWith(
                  color: tokens.textMuted,
                  fontSize: 10,
                ),
              ),
            ],
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

  void _showMessageMenu(BuildContext context, Message message, Offset position) {
    if (isMessageDeleted(message)) return;
    final text = _getMessageText(message);
    final isSentByMe = message.authorId == widget.userId;
    final danger = context.prysmStyle.tokens.danger;
    final tiles = <Widget>[
      if (text.isNotEmpty)
        PrysmListRow(
          leading: const Icon(PrysmIcons.copy),
          title: 'Copy',
          onTap: () {
            Navigator.pop(context);
            Clipboard.setData(ClipboardData(text: text));
            showPrysmToast(context, 'Copied to clipboard');
          },
        ),
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
        leading: Icon(PrysmIcons.deleteOutline, color: danger),
        title: isSentByMe ? 'Delete for everyone' : 'Delete',
        onTap: () {
          Navigator.pop(context);
          _deleteMessage(message);
        },
      ),
    ];

    showMessageActionsSheet(
      context: context,
      onReactionSelected: (emoji) => _onReactionSelected(message, emoji),
      actionTiles: tiles,
    );
  }

  Future<void> _deletePendingMessage(Message message) async {
    final id = message.id;
    await PendingMessageDbHelper.removeOutboundPendingForWireId(id);
    _chatService.cancelPendingSend(id);
    await MessageContentWiper.wipeLocalArtifacts(wireId: id);
    await MessagesDb.deleteMessageById(id);
    await MessageReactionsDb.deleteReactionsForMessage(id);
    _messageCache.remove(id);
    if (!mounted) return;
    setState(() {
      _messages.removeMessage(message);
      selectedMessageIds.remove(id);
    });
  }

  Future<void> _deleteMessage(Message message) async {
    if (message.authorId == widget.userId && isOutboundPending(message)) {
      await _deletePendingMessage(message);
      return;
    }

    if (canDeleteForEveryone(message, widget.userId)) {
      await _modifyService.deleteMessage(targetMessageId: message.id);
      await MessageReactionsDb.deleteReactionsForMessage(message.id);
      _messageCache.remove(message.id);
      if (!mounted) return;
      setState(() {
        _messages.updateMessage(message, markMessageDeleted(message));
        selectedMessageIds.remove(message.id);
      });
      return;
    }

    await MessageContentWiper.wipeLocalArtifacts(wireId: message.id);
    await MessagesDb.deleteMessageById(message.id);
    await MessageReactionsDb.deleteReactionsForMessage(message.id);
    _messageCache.remove(message.id);
    if (!mounted) return;
    setState(() {
      _messages.removeMessage(message);
      selectedMessageIds.remove(message.id);
    });
  }

  void _resendMessage(Message message) {
    _chatService.resendMessage(message.id);
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
      messageAuthorId: message.authorId,
      directPeerId: widget.peerId,
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

  Future<void> deleteSelectedMessages() async {
    final ids = List<String>.from(selectedMessageIds);
    for (final id in ids) {
      final message = _messages.messages.firstWhere((msg) => msg.id == id);
      if (message.authorId == widget.userId && isOutboundPending(message)) {
        await _deletePendingMessage(message);
        continue;
      }
      if (canDeleteForEveryone(message, widget.userId)) {
        await _modifyService.deleteMessage(targetMessageId: id);
        await MessageReactionsDb.deleteReactionsForMessage(id);
        _messageCache.remove(id);
        if (mounted) {
          setState(() {
            _messages.updateMessage(message, markMessageDeleted(message));
          });
        }
      } else {
        await MessageContentWiper.wipeLocalArtifacts(wireId: id);
        await MessagesDb.deleteMessageById(id);
        await MessageReactionsDb.deleteReactionsForMessage(id);
        _messageCache.remove(id);
        if (mounted) {
          setState(() {
            _messages.removeMessage(message);
          });
        }
      }
    }

    if (mounted) {
      setState(() => selectedMessageIds.clear());
    }
  }

  // ==================== BUILD METHOD (KEEP EXACTLY AS-IS) ====================

  void _showProfileSheet() {
    showPrysmSheet(
      context: context,
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          PrysmListRow(
            leading: ContactAvatar(
              name: _peerName,
              radius: 20,
              avatarBase64: _peerAvatarBase64,
            ),
            title: _peerName,
            subtitle: _isPeerBlocked ? 'Blocked · View profile' : 'View profile',
            onTap: () {
              Navigator.pop(ctx);
              _openChatProfile();
            },
          ),
        ],
      ),
    );
  }

  Widget _buildChatTitle() {
    final tokens = context.prysmStyle.tokens;
    final style = context.prysmStyle;
    return GestureDetector(
      onTap: _showProfileSheet,
      child: Row(
        children: [
          RepaintBoundary(
            child: ContactAvatar(
              name: _peerName,
              radius: 20,
              avatarBase64: _peerAvatarBase64,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  _peerName,
                  style: style.titleStyle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                if (_isPeerBlocked)
                  Text(
                    'Blocked',
                    style: style.captionStyle.copyWith(
                      color: tokens.textMuted,
                      fontWeight: FontWeight.w500,
                    ),
                  )
                else if (_peerOnline == null)
                  Text(
                    'Checking...',
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
                          color: _peerOnline!
                              ? tokens.accent
                              : tokens.textPrimary.withAlpha(100),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        _peerOnline! ? 'Online' : 'Offline',
                        style: style.captionStyle.copyWith(
                          color: _peerOnline!
                              ? tokens.accent
                              : tokens.textMuted,
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
    );
  }

  List<Widget> _buildAppBarActions() {
    if (selectedMessageIds.isNotEmpty) {
      return [
        if (widget.torStatusAction != null) widget.torStatusAction!,
        PrysmIconButton(
          icon: PrysmIcons.delete,
          onPressed: deleteSelectedMessages,
        ),
        PrysmIconButton(
          icon: PrysmIcons.moreVert,
          onPressed: _openChatProfile,
        ),
      ];
    }
    return [
      if (widget.torStatusAction != null) widget.torStatusAction!,
      PrysmIconButton(
        icon: PrysmIcons.phone,
        onPressed: _canStartCall ? _startAudioCall : null,
      ),
      PrysmIconButton(
        icon: PrysmIcons.moreVert,
        onPressed: _openChatProfile,
      ),
    ];
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
      titleWidget: _buildChatTitle(),
      actions: _buildAppBarActions(),
      body: PrysmChatDropTarget(
        enabled: !_isPeerBlocked,
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
                itemBuilder: _buildChatListItem,
              ),
            ),
            if (_isPeerBlocked)
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 14,
                ),
                decoration: BoxDecoration(
                  color: context.prysmTokens.surfaceElevated,
                  border: Border(
                    top: BorderSide(color: context.prysmTokens.divider),
                  ),
                ),
                child: Text(
                  'Unblock to send messages',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: context.prysmTokens.textMuted),
                ),
              )
            else
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

  Widget _buildCallMessageRow(PrysmCallMessage message, int index) {
    final showDateHeader = shouldShowChatDateHeader(_messages.messages, index);
    return Column(
      children: [
        if (showDateHeader) PrysmDateHeader(date: message.createdAt!),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: _callMessageBuilder(message),
        ),
      ],
    );
  }

  Widget _messageChildFor(
    BuildContext context,
    Message message,
    int index,
    bool isSentByMe,
  ) {
    if (message is TextMessage) {
      return textMessageBuilder(
        context,
        message,
        index,
        isSentByMe: isSentByMe,
      );
    }
    if (message is ImageMessage) {
      return myImageMessageBuilder(
        context,
        message,
        index,
        isSentByMe: isSentByMe,
      );
    }
    if (message is FileMessage) {
      return fileMessageBuilder(
        context,
        message,
        index,
        isSentByMe: isSentByMe,
      );
    }
    if (message is PrysmCallMessage) {
      return _callMessageBuilder(message);
    }
    return const SizedBox.shrink();
  }

  Widget _buildChatListItem(BuildContext context, Message message, int index) {
    final isSentByMe = message.authorId == widget.userId;

    if (message is PrysmCallMessage) {
      return _buildCallMessageRow(message, index);
    }

    final isSelected = selectedMessageIds.contains(message.id);
    final child = _messageChildFor(context, message, index, isSentByMe);

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
      onLongPressMenu: (position) =>
          _showMessageMenu(context, message, position),
      displayChild: _displayChildForMessage(message, child, isSentByMe),
      reactionBar: isMessageDeleted(message)
          ? const SizedBox.shrink()
          : _reactionBarFor(message, isSentByMe),
    );
  }

  // ==================== MESSAGE BUILDERS (KEEP AS-IS) ====================

  Widget myImageMessageBuilder(
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
        "${msgDate.hour.toString().padLeft(2, '0')}:${msgDate.minute.toString().padLeft(2, '0')}";

    // ✅ Determine tick status
    Widget tickWidget = const SizedBox.shrink();
    if (isSentByMe) {
      tickWidget = _buildStatusWidget(
        message,
        isSentByMe,
        context.prysmStyle.tokens.onAccent.withAlpha(220),
      );
    }

    // View-once: already viewed → show "Opened" placeholder
    if (isViewOnce && isViewed) {
      final muted = context.prysmStyle.tokens.textMuted;
      return _wrapWithReplyQuote(
        message,
        isSentByMe,
        Column(
        crossAxisAlignment: isSentByMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
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
        ),
      );
    }

    // View-once: not yet viewed → show blurred placeholder with eye icon
    if (isViewOnce && !isViewed) {
      return _wrapWithReplyQuote(
        message,
        isSentByMe,
        Column(
        crossAxisAlignment: isSentByMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onTap: () async {
              if (isSentByMe) return; // Sender can't re-view
              // Decrypt, show viewer, then wipe
              final msg = await MessagesDb.getMessageById(message.id);
              if (msg.isEmpty || msg.first['message'] == null) return;
              try {
                final decryptedBytes = await decryptFileInBackground(msg.first, widget.keyManager);
                if (!context.mounted) return;
                await Navigator.push(
                  context,
                  PrysmPageRoute(page: _ViewOnceScreen(imageBytes: decryptedBytes),
                  ),
                );
                // After closing viewer, mark as viewed and wipe content
                await MessagesDb.markViewOnceViewed(message.id);
                if (!mounted) return;
                // Update the in-memory message to show "Opened"
                setState(() {
                  _messages.updateMessage(
                    message,
                    message.copyWith(
                      source: "",
                      metadata: {'viewOnce': true, 'viewed': true},
                    ),
                  );
                });
              } catch (e) {
                print('View-once decrypt failed: $e');
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
                  const SizedBox(height: 4),
                  Text(
                    '🔒 Disappears after viewing',
                    style: TextStyle(
                      fontSize: 11,
                      color: context.prysmStyle.tokens.textMuted,
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
              Icon(
                PrysmIcons.timer,
                size: 12,
                color: context.prysmStyle.tokens.textMuted,
              ),
              const SizedBox(width: 2),
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
        ),
      );
    }

    return _wrapWithReplyQuote(
      message,
      isSentByMe,
      ImageMessageBubble(
      message: message,
      isSentByMe: isSentByMe,
      timeString: timeString,
      tickWidget: tickWidget,
      decryptFromDb: () => _decryptImageFromDb(message.id),
      ),
    );
  }

  Widget fileMessageBuilder(
    BuildContext context,
    FileMessage message,
    int index, {
    required bool isSentByMe,
  }) {
    if (message.name.contains('voice_message') ||
        message.source.startsWith('audio:')) {
      return _voiceMessageBuilder(
        context,
        message,
        index,
        isSentByMe: isSentByMe,
      );
    }

    final msgDate = DateTime.fromMillisecondsSinceEpoch(
      message.createdAt!.millisecondsSinceEpoch,
    );
    final timeString =
        '${msgDate.hour.toString().padLeft(2, '0')}:${msgDate.minute.toString().padLeft(2, '0')}';

    Widget tickWidget = const SizedBox.shrink();
    if (isSentByMe) {
      final tickColor = context.prysmStyle.tokens.onAccent;
      tickWidget =
          _buildStatusWidget(message, isSentByMe, tickColor.withAlpha(220));
    }

    return _wrapWithReplyQuote(
      message,
      isSentByMe,
      FileAttachmentBubble(
      fileName: message.name,
      fileSize: message.size,
      timeString: timeString,
      isSentByMe: isSentByMe,
      tickWidget: tickWidget,
      resolveBytes: () => FileAttachmentResolver.resolve(
        message,
        keyManager: widget.keyManager,
      ),
      ),
    );
  }

  Widget textMessageBuilder(
    BuildContext context,
    TextMessage message,
    int index, {
    required bool isSentByMe,
  }) {
    final msgDate = DateTime.fromMillisecondsSinceEpoch(
      message.createdAt!.millisecondsSinceEpoch,
    );
    final timeString =
        "${msgDate.hour.toString().padLeft(2, '0')}:${msgDate.minute.toString().padLeft(2, '0')}";

    // ✅ Determine tick status
    Widget tickWidget = const SizedBox.shrink();
    if (isSentByMe) {
      final tickColor = prysmBubbleMetaColor(context, isSentByMe: isSentByMe);
      tickWidget = _buildStatusWidget(message, isSentByMe, tickColor);
    }

    final textColor = prysmBubbleTextColor(context, isSentByMe: isSentByMe);
    final metaColor = prysmBubbleMetaColor(context, isSentByMe: isSentByMe);
    final bodyStyle = context.prysmStyle.bodyStyle.copyWith(color: textColor);

    return IntrinsicWidth(
      child: PrysmBubbleRenderer(
        isSentByMe: isSentByMe,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            _replyQuoteFor(message, isSentByMe),
            LinkedMessageText(
              text: message.text,
              textColor: textColor,
              fontSize: bodyStyle.fontSize ?? 15,
              onOpenUrl: _openUrl,
            ),
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerRight,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (message.metadata?['edited'] == true) ...[
                    Text(
                      'edited',
                      style: context.prysmStyle.captionStyle.copyWith(
                        fontStyle: FontStyle.italic,
                        color: metaColor,
                      ),
                    ),
                    const SizedBox(width: 4),
                  ],
                  Text(
                    timeString,
                    style: context.prysmStyle.captionStyle.copyWith(
                      color: metaColor,
                    ),
                  ),
                  if (isSentByMe) ...[const SizedBox(width: 4), tickWidget],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _voiceMessageBuilder(
    BuildContext context,
    FileMessage message,
    int index, {
    required bool isSentByMe,
  }) {
    final msgDate = DateTime.fromMillisecondsSinceEpoch(
      message.createdAt!.millisecondsSinceEpoch,
    );
    final timeString =
        "${msgDate.hour.toString().padLeft(2, '0')}:${msgDate.minute.toString().padLeft(2, '0')}";

    final tickColor = isSentByMe
        ? context.prysmStyle.tokens.onAccent
        : context.prysmStyle.tokens.textPrimary;
    Widget tickWidget = _buildStatusWidget(message, isSentByMe, tickColor.withAlpha(220));

    return _wrapWithReplyQuote(
      message,
      isSentByMe,
      VoiceMessageBubble(
      message: message,
      isSentByMe: isSentByMe,
      timeString: timeString,
      tickWidget: tickWidget,
      decryptAudio: message.source.startsWith('audio:')
          ? null
          : (encryptedSource) async {
              return CryptoWire.decryptFile(
                encryptedSource,
                widget.keyManager.identity,
              );
            },
      ),
    );
  }
}

// ==================== VIEW ONCE SCREEN ====================

class _ViewOnceScreen extends StatefulWidget {
  final Uint8List imageBytes;
  const _ViewOnceScreen({required this.imageBytes});

  @override
  State<_ViewOnceScreen> createState() => _ViewOnceScreenState();
}

class _ViewOnceScreenState extends State<_ViewOnceScreen> {
  static const _flagSecureChannel = MethodChannel('prysm/flag_secure');

  @override
  void initState() {
    super.initState();
    _enableScreenshotPrevention();
  }

  @override
  void dispose() {
    _disableScreenshotPrevention();
    super.dispose();
  }

  Future<void> _enableScreenshotPrevention() async {
    if (Platform.isAndroid) {
      try {
        await _flagSecureChannel.invokeMethod('enable');
      } catch (_) {
        // Fallback: no-op if platform channel isn't wired yet
      }
    }
  }

  Future<void> _disableScreenshotPrevention() async {
    if (Platform.isAndroid) {
      try {
        await _flagSecureChannel.invokeMethod('disable');
      } catch (_) {}
    }
  }

  @override
  Widget build(BuildContext context) {
    const overlay = Color(0xB3FFFFFF);
    return PrysmPage(
      backgroundColor: const Color(0xFF000000),
      title: 'View Once',
      leading: PrysmIconButton(
        icon: PrysmIcons.close,
        color: overlay,
        onPressed: () => Navigator.of(context).pop(),
      ),
      body: Center(
        child: InteractiveViewer(
          child: Image.memory(widget.imageBytes),
        ),
      ),
    );
  }
}

