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

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:prysm/models/chat/prysm_message.dart';
import 'package:prysm/ui/chat/prysm_chat_message_list.dart';
import 'package:prysm/util/file_bytes_reader.dart';
import 'package:prysm/util/logging.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:prysm/services/message_draft_store.dart';
import 'package:prysm/services/scheduled_message_service.dart';
import 'package:prysm/services/block_service.dart';
import 'package:prysm/services/call/call_manager.dart';
import 'package:prysm/transport/transport_preference.dart';
import 'package:prysm/transport/transport_provider.dart';
import 'package:prysm/util/peer_ws_connection_notifier.dart';
import 'package:prysm/util/tor_runtime_gate.dart';
import 'package:prysm/database/messages.dart';
import 'package:prysm/screens/chat_profile_screen.dart';
import 'package:prysm/ui/chat/prysm_bubble_renderer.dart';
import 'package:prysm/ui/chat/prysm_chat_composer_column.dart';
import 'package:prysm/ui/chat/prysm_constrained_composer.dart';
import 'package:prysm/ui/chat/prysm_chat_list.dart';
import 'package:prysm/ui/chat/chat_search_bar.dart';
import 'package:prysm/ui/chat/prysm_date_header.dart';
import 'package:prysm/ui/chat/prysm_message_row.dart';
import 'package:prysm/theme/prysm_style_scope.dart';
import 'package:prysm/theme/prysm_theme.dart';
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
import 'package:prysm/screens/widgets/view_once_image_screen.dart';
import 'package:prysm/screens/widgets/disappearing_messages_tile.dart';
import 'package:prysm/services/disappearing_timer_service.dart';
import 'package:prysm/util/disappearing_timer_refresh_notifier.dart';
import 'package:prysm/util/reply_preview_label.dart';
import 'package:prysm/services/file_attachment_resolver.dart';
import 'package:prysm/services/file_transfer_progress.dart';
import 'package:prysm/screens/widgets/deleted_message_bubble.dart';
import 'package:prysm/services/message_modify_service.dart';
import 'package:prysm/services/message_actions_service.dart';
import 'package:prysm/services/message_view_mapper.dart';
import 'package:prysm/services/reaction_service.dart';
import 'package:prysm/services/read_receipt_service.dart';
import 'package:prysm/services/chat_screen_controller.dart';
import 'package:prysm/services/peer_presence_tracker.dart';
import 'package:prysm/services/settings_service.dart';
import 'package:prysm/screens/widgets/message_status_icon.dart';
import 'package:prysm/screens/widgets/read_receipt_details_sheet.dart';
import 'package:prysm/util/message_status_mapper.dart';
import 'package:prysm/util/read_receipt_refresh_notifier.dart';
import 'package:prysm/util/message_modify_policy.dart';
import 'package:prysm/util/message_modify_refresh_notifier.dart';
import 'package:prysm/util/notification_service.dart';
import 'package:prysm/util/reaction_refresh_notifier.dart';
import 'package:prysm/services/battery_saver_service.dart';
import 'package:prysm/services/detached_chat_client.dart';
import 'package:prysm/services/chat_service.dart';
import 'package:prysm/services/conversation_preferences_service.dart';
import 'package:prysm/services/typing_indicator_service.dart';
import 'package:prysm/services/typing_state_tracker.dart';
import 'package:prysm/util/typing_indicator_notifier.dart';
import 'package:prysm/util/battery_saver_policy.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/crypto/constants.dart';
import 'package:prysm/crypto/wire.dart';
import 'package:prysm/util/tor_service.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:prysm/models/contact.dart';

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
  final String? initialScrollToMessageId;

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
    this.initialScrollToMessageId,
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

  late ChatScreenController _controller;
  final Map<String, Message> _messageCache = {};
  PrysmChatMessageList get _messages => _controller.messages;
  Set<String> get selectedMessageIds => _controller.selectedMessageIds;

  String _peerName = '';
  String? _peerAvatarBase64;
  // ignore: unused_field
  int _currentTheme = 0;
  bool? _peerOnline;
  late PeerPresenceTracker _presenceTracker;
  Timer? _presenceStaleTimer;
  StreamSubscription<PeerWsConnectionEvent>? _wsPresenceSub;
  StreamSubscription<void>? _batterySaverSub;

  final ValueNotifier<double> _swipeDragOffset = ValueNotifier(0);
  String? _swipeDragMessageId;

  final ScrollController _listScrollController = ScrollController();
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
  late MessageModifyService _modifyService;
  late MessageViewMapper _viewMapper;
  late MessageActionsService _actionsService;
  String? _highlightedMessageId;
  Timer? _highlightTimer;
  bool _showChatSearch = false;
  String _chatHighlightQuery = '';
  late TypingIndicatorService _typingService;
  final _typingTracker = TypingStateTracker();
  StreamSubscription<TypingIndicatorEvent>? _typingSub;
  StreamSubscription<void>? _typingTrackerSub;
  int? _disappearingTimerSeconds;
  StreamSubscription<String>? _disappearingTimerSub;

  String get _draftKey => 'dm:${widget.peerId}';

  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  // Stable forwarder registered once in initState so scroll updates always
  // reach the *current* `_controller`, even after didUpdateWidget rebuilds
  // it on peerId change. Never rebind addListener/removeListener to the
  // controller's own tear-off — that pins the listener to whichever
  // controller instance existed at registration time and it silently stops
  // firing (or throws "used after being disposed") once that instance is
  // replaced.
  void _onListScrollForward() => _controller.onListScroll();

  ChatScreenController _buildController() {
    return ChatScreenController(
      localUserId: widget.userId,
      draftKey: _draftKey,
      listScrollController: _listScrollController,
      isMounted: () => mounted,
      messageCache: _messageCache,
      typingTracker: _typingTracker,
      typingService: _typingService,
      conversationKey: widget.peerId,
      matchesTypingEvent: (e) => e.groupId == null && e.senderId == widget.peerId,
      typingIndicatorsEnabled: () => _settings.enableTypingIndicators,
      typistDisplayName: (id) => _peerName.isNotEmpty ? _peerName : id,
      reactionService: _reactionService,
      readReceiptService: _readReceiptService,
      markInboundRead: () => MessagesDb.markInboundConversationRead(widget.userId, widget.peerId),
      cancelForegroundNotification: () => unawaited(
        NotificationService().cancelConversationNotificationIfForeground(
          senderId: widget.peerId,
        ),
      ),
      sendReadReceiptsEnabled: () => _settings.sendReadReceipts,
      requiredReadCount: () => 1,
      gateWaterlineSendOnMounted: true,
      onNewlyRead: _recordPeerActivity,
      fetchMessageBatch: ({beforeTimestamp, beforeId}) => MessagesDb.getMessagesBetweenBatchWithId(
        widget.userId,
        widget.peerId,
        limit: 20,
        beforeTimestamp: beforeTimestamp,
        beforeId: beforeId,
      ),
      decryptForDisplay: _decryptForDisplay,
      seedNewestTimestamp: _chatService.seedNewestTimestamp,
      onToast: (msg) => showPrysmToast(context, msg),
      onLargeFileUploadStart: (id) => FileTransferProgress.uploadNotifier(id),
      onFileMessageRemoved: (id) => FileTransferProgress.clearUpload(id),
      dispatchText: _dispatchText,
      dispatchFile: _dispatchFile,
      dispatchVoice: _dispatchVoice,
    );
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
    _viewMapper = MessageViewMapper(keyManager: widget.keyManager);
    _actionsService = MessageActionsService(
      modifyService: _modifyService,
      cancelPendingSend: _chatService.cancelPendingSend,
    );
    _typingService = TypingIndicatorService.direct(
      userId: widget.userId,
      peerId: widget.peerId,
      settings: _settings,
    );
    _controller = _buildController();
    _controller.addListener(_onControllerChanged);
    _setupTypingSubscriptions();

    _presenceTracker = PeerPresenceTracker();
    _listScrollController.addListener(_onListScrollForward);
    _initializeChat();
    _initPeerPresence();
    _setupDetachedClientSubscriptions();
    unawaited(_loadDisappearingTimer());
    _setupDisappearingTimerSubscription();
    _batterySaverSub = BatterySaverService.instance.onChanged.listen((_) {
      if (mounted) {
        _startPresenceStaleTimer();
      }
    });
  }

  Future<void> _loadDisappearingTimer() async {
    final seconds =
        await DisappearingTimerService.getTimerSeconds(widget.peerId);
    if (!mounted) return;
    setState(() => _disappearingTimerSeconds = seconds);
  }

  void _setupDisappearingTimerSubscription() {
    _disappearingTimerSub?.cancel();
    _disappearingTimerSub =
        DisappearingTimerRefreshNotifier.instance.onChanged.listen((id) {
      if (id == widget.peerId) unawaited(_loadDisappearingTimer());
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
    _reactionSub = _reactionService.onReactionsChanged.listen(_controller.applyReactionUpdate);
    _reactionRefreshSub =
        ReactionRefreshNotifier.instance.onReactionChanged.listen(_controller.applyReactionUpdate);
    _modifyRefreshSub = MessageModifyRefreshNotifier.instance.onModifyChanged
        .listen(_applyModifyUpdate);
    _readReceiptRefreshSub =
        ReadReceiptRefreshNotifier.instance.onReadReceiptChanged
            .listen(_controller.applyReadReceiptUpdate);

    await _loadInitialMessages();
    _controller.restoreReplyDraft();
    await _controller.markInboundAsRead();

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

    // ✅ Start ChatService background tasks (main window only)
    if (widget.detachedClient == null) {
      _chatService.startPolling();
      _chatService.startSendQueue();
      if (TransportProvider.isConfigured) {
        TransportProvider.instance.pinPeer(widget.peerId);
      }
    }
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
      _controller.scheduleScrollToBottomIfNeeded();
      await _controller.markInboundAsRead();
    } catch (e) {
      Logging.error('Error handling new messages: $e', 'ChatScreen');
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
    _disappearingTimerSub?.cancel();
    _disappearingTimerSub = null;
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
      _controller.scheduleScrollToBottomIfNeeded();
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
        TypingIndicatorNotifier.instance.events.listen(_controller.onTypingEvent);
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
    _listScrollController.removeListener(_onListScrollForward);
    _listScrollController.dispose();
    _controller.removeListener(_onControllerChanged);
    _controller.dispose();
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
      // The peer's advertised ratchet scheme warms the send-path cache so
      // the first message to this peer never needs a profile fetch.
      final ratchetScheme = CryptoConstants.parseRatchetScheme(
        data['ratchetScheme'],
      );
      if (ratchetScheme != null) {
        updates['ratchetScheme'] = ratchetScheme;
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
      Logging.error('Profile refresh failed: $e', 'ChatScreen');
    }
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
      _controller.removeListener(_onControllerChanged);
      _controller.dispose();

      _presenceTracker = PeerPresenceTracker();
      if (mounted) {
        setState(() {
          _messageCache.clear();
          _peerName = widget.peerName;
          _peerAvatarBase64 = widget.peerAvatarBase64;
          _peerOnline = null;
          _disappearingTimerSeconds = null;
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
      _viewMapper = MessageViewMapper(keyManager: widget.keyManager);
      _actionsService = MessageActionsService(
        modifyService: _modifyService,
        cancelPendingSend: _chatService.cancelPendingSend,
      );
      _typingService = TypingIndicatorService.direct(
        userId: widget.userId,
        peerId: widget.peerId,
        settings: _settings,
      );
      _controller = _buildController();
      _controller.addListener(_onControllerChanged);
      _setupTypingSubscriptions();
      _setupDetachedClientSubscriptions();
      _batterySaverSub = BatterySaverService.instance.onChanged.listen((_) {
        if (mounted) {
          _startPresenceStaleTimer();
        }
      });

      _initializeChat();
      _initPeerPresence();
      unawaited(_loadDisappearingTimer());
      _setupDisappearingTimerSubscription();
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

    final scrollId = widget.initialScrollToMessageId;
    if (scrollId != null &&
        scrollId != oldWidget.initialScrollToMessageId &&
        oldWidget.peerId == widget.peerId) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(_scrollToMessage(scrollId));
      });
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
          _messageCache.remove(msg.id);
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

    final updated = await _actionsService.editTextMessage(message, editedText);
    if (!mounted) return;
    if (updated != null) {
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
      senderId: msg['senderId'] as String?,
      localUserId: widget.userId,
      allowLegacyUnsignedFile: true,
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

  Future<List<Message>> _decryptForDisplay(
    List<Map<String, dynamic>> rawMessages,
  ) async {
    if (widget.detachedClient != null) {
      return widget.detachedClient!.decryptRows(rawMessages);
    }
    return _viewMapper.mapDirectRows(
      rawMessages,
      localUserId: widget.userId,
      cache: _messageCache,
      loadReactionsForMessages: _reactionService.loadReactionsForMessages,
      readReceiptsEnabled: _settings.sendReadReceipts,
    );
  }

  // ==================== MESSAGE LOADING (KEEP AS-IS) ====================

  Future<void> _loadInitialMessages() async {
    await _controller.loadMoreMessages();
  }

  Future<void> _sendFileFromPath(String path, String fileName) async {
    if (!mounted) return;

    final fileSize = await fileSizeDeferred(path);
    if (!mounted) return;
    if (_controller.rejectOversizedFile(fileSize)) return;

    Uint8List bytes;
    try {
      bytes = await readFileBytesDeferred(path);
    } catch (e) {
      if (!mounted) return;
      showPrysmToast(context, 'Could not read file: $e');
      return;
    }
    if (!mounted) return;

    await _controller.sendFile(bytes, fileName, 'file');
  }

  Future<void> _dispatchText({
    required String text,
    required String messageId,
    String? replyToId,
  }) async {
    if (widget.detachedClient != null) {
      widget.detachedClient!
          .sendText(text: text, replyToId: replyToId, messageId: messageId)
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

  Future<bool> _scheduleText(String text, DateTime sendAt) async {
    try {
      await ScheduledMessageService(
        userId: widget.userId,
        keyManager: widget.keyManager,
      ).schedule(
        conversationId: widget.peerId,
        isGroup: false,
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
    if (!mounted) return;

    final String? sentId;
    if (widget.detachedClient != null) {
      sentId = await widget.detachedClient!.sendFile(
        bytes: bytes,
        fileName: fileName,
        type: type,
        replyToId: replyToId,
        messageId: messageId,
        viewOnce: viewOnce,
      );
    } else {
      sentId = await _chatService.sendFileMessage(
        bytes,
        fileName,
        type,
        replyToId: replyToId,
        messageId: messageId,
        viewOnce: viewOnce,
      );
    }

    if (!mounted) return;
    if (sentId != null) return;

    final stored = await MessagesDb.getMessageById(messageId);
    if (stored.isEmpty) {
      _controller.removeOptimisticFileMessage(messageId);
      return;
    }

    if (!mounted) return;
    showPrysmToast(
      context,
      'File queued. Will send when peer is available.',
    );
  }

  Future<void> _dispatchVoice({
    required Uint8List bytes,
    required int durationMs,
    required String messageId,
    String? replyToId,
    required String cachePath,
  }) async {
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
      sendFile: _controller.sendFile,
      forceImageFlow: true,
    );
  }

  Future<void> _handleSendFile() async {
    final result = await FilePicker.platform.pickFiles(withData: false);
    if (result == null || result.files.isEmpty) return;

    final file = result.files.first;
    final path = file.path;
    if (path == null || path.isEmpty) return;
    if (!mounted) return;
    if (file.size > 0 && _controller.rejectOversizedFile(file.size)) return;

    if (ChatAttachmentIngress.isImageFileName(file.name)) {
      final bytes = await readFileBytesDeferred(path);
      if (!mounted) return;
      await ChatAttachmentIngress.sendLocalAttachment(
        context: context,
        bytes: bytes,
        fileName: file.name,
        sendFile: _controller.sendFile,
      );
      return;
    }

    await _sendFileFromPath(path, file.name);
  }

  Future<void> _handleDroppedFile(String path, String name) async {
    if (!mounted) return;

    if (ChatAttachmentIngress.isImageFileName(name)) {
      try {
        final bytes = await readFileBytesDeferred(path);
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
      return;
    }

    await _sendFileFromPath(path, name);
  }

  // ==================== UI HELPERS (KEEP AS-IS) ====================

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
            _controller.resetConversation();
            MessageDraftStore.instance.setReply(_draftKey, null);
            _loadInitialMessages();
          },
          onDeleteContact: () async {
            await ConversationPreferencesService.instance.delete(widget.peerId);
            await DBHelper.deleteUser(widget.peerId);
            _controller.resetConversation();
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
    final data = _controller.replyToMessage != null
        ? replyPreviewFromMessage(_controller.replyToMessage!)
        : _controller.replyDraft;
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
                _controller.clearReplyState();
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
          _controller.setReplyToMessage(message);
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
      onReactionSelected: (emoji) => _controller.onReactionSelected(message, emoji),
      actionTiles: tiles,
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
    _messageCache.remove(message.id);
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
      selectedMessageIds.remove(message.id);
    });
    if (showFailureToast &&
        outcome == MessageDeleteOutcome.markedDeletedForEveryoneFailed) {
      showPrysmToast(context, 'Could not delete for everyone');
    }
    return outcome;
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
    var failed = 0;
    for (final id in ids) {
      final message = _messages.messages.firstWhere((msg) => msg.id == id);
      final outcome = await _deleteMessage(message, showFailureToast: false);
      if (outcome == MessageDeleteOutcome.markedDeletedForEveryoneFailed) {
        failed++;
      }
    }

    if (mounted) {
      setState(() => selectedMessageIds.clear());
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
            child: DisappearingTimerAvatar(
              name: _peerName,
              radius: 20,
              avatarBase64: _peerAvatarBase64,
              timerSeconds: _disappearingTimerSeconds,
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
        icon: PrysmIcons.search,
        onPressed: () => setState(() {
          _showChatSearch = !_showChatSearch;
          if (!_showChatSearch) _chatHighlightQuery = '';
        }),
      ),
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
      bottom: _showChatSearch
          ? ChatSearchBar(
              conversationId: widget.peerId,
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
        enabled: !_isPeerBlocked,
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
                // With the keyboard open the app content is padded by the
                // full keyboard inset (PrysmApp), so the composer (reply
                // preview + typing bar + input row) can be taller than the
                // body's remaining height; constrain and scroll it instead of
                // overflowing the body Column.
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

  Widget _buildDisappearingTimerNoticeRow(TextMessage message, int index) {
    final timerSeconds = message.metadata?['timerSeconds'] as int?;
    final actorId = message.metadata?['actorId'] as String? ?? message.authorId;
    final label = disappearingTimerNoticeLabel(
      timerSeconds: timerSeconds,
      actorId: actorId,
      localUserId: widget.userId,
      actorDisplayName: actorId == widget.peerId ? _peerName : null,
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

    if (message is TextMessage &&
        message.metadata?['systemNotice'] == 'disappearing_timer') {
      return _buildDisappearingTimerNoticeRow(message, index);
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
      onReply: () => _controller.setReplyToMessage(message),
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
                  PrysmPageRoute(page: ViewOnceImageScreen(
                    imageBytes: decryptedBytes,
                    title: 'View Once',
                    closeColor: const Color(0xB3FFFFFF),
                  ),
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
                Logging.error('View-once decrypt failed: $e', 'ChatScreen');
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
      uploadProgress: isSentByMe
          ? FileTransferProgress.uploadFor(message.id)
          : null,
      downloadProgress: !isSentByMe
          ? FileTransferProgress.downloadFor(message.id)
          : null,
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
              highlightQuery:
                  _showChatSearch ? _chatHighlightQuery : null,
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

