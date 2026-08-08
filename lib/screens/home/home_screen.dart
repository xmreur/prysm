/// Home shell screen: conversation list, chat/group/self panes, settings
/// and profile overlays, contact/group actions, blocked/archived views,
/// call handling, and the online-services wiring hookup.
///
/// Moved verbatim from `main.dart` (Fase 5B): `HomeScreen` was the last
/// large widget still living in the entry-point file. No behavior change —
/// same fields, same lifecycle, same delegation to
/// `ConversationListRepository`/`AppComposition`/`TorConnectionController`.
library;

import 'package:flutter/widgets.dart';
import 'package:prysm/ui/core/prysm_icons.dart';
import 'package:prysm/ui/core/prysm_progress.dart';
import 'package:prysm/ui/core/prysm_toast.dart';
import 'package:prysm/theme/prysm_style_scope.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:prysm/app/app_composition.dart';
import 'package:prysm/app/conversation_list_repository.dart';
import 'package:prysm/app/tor_connection_controller.dart';
import 'package:prysm/screens/settings_screen.dart';
import 'package:prysm/services/battery_saver_service.dart';
import 'package:prysm/services/block_service.dart';
import 'package:prysm/services/active_conversation_tracker.dart';
import 'package:prysm/services/notification_open_chat_resolver.dart';
import 'package:prysm/services/pending_call_action.dart';
import 'package:prysm/services/pending_notification_route.dart';
import 'package:prysm/services/pending_share_store.dart';
import 'package:prysm/services/share_intent_service.dart';
import 'package:prysm/services/settings_service.dart';
import 'package:prysm/util/battery_saver_policy.dart';
import 'package:prysm/services/tray_service.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/logging.dart';
import 'package:prysm/services/app_update_service.dart';
import 'package:prysm/services/call/call_foreground_session.dart';
import 'package:prysm/services/call/call_manager.dart';
import 'package:prysm/screens/chat.dart';
import 'package:prysm/screens/self_chat_screen.dart';
import 'package:prysm/screens/create_group_screen.dart';
import 'package:prysm/screens/group_chat.dart';
import 'package:prysm/models/conversation.dart';
import 'package:prysm/models/conversation_preferences.dart';
import 'package:prysm/models/group.dart';
import 'package:prysm/services/conversation_preferences_service.dart';
import 'package:prysm/models/detached_chat_launch.dart';
import 'package:prysm/models/share_target.dart';
import 'package:prysm/screens/share_target_picker_screen.dart';
import 'package:prysm/services/detached_chat_bridge.dart';
import 'package:prysm/services/detached_chat_host.dart';
import 'package:prysm/services/detached_chat_window_registry.dart';
import 'package:prysm/screens/widgets/conversation_context_menu.dart';
import 'package:prysm/screens/widgets/conversation_actions_sheet.dart';
import 'package:prysm/services/group_service.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/util/desktop_platform.dart';
import 'package:prysm/util/tor_service.dart'; // Updated Tor service
import 'package:prysm/transport/transport_provider.dart';
import 'package:prysm/screens/profile_screen.dart';
import 'package:prysm/screens/widgets/contact_avatar.dart';
import 'package:prysm/models/contact.dart';
import 'package:prysm/theme/prysm_theme.dart';
import 'package:prysm/screens/home/empty_home_state.dart';
import 'package:prysm/database/messages.dart';
import 'package:prysm/models/message_search_hit.dart';
import 'package:prysm/screens/home/message_search_result_row.dart';
import 'package:prysm/services/message_search_index_service.dart';
import 'package:prysm/ui/prysm_list_row.dart';
import 'package:prysm/ui/prysm_search_field.dart';
import 'package:prysm/ui/core/prysm_app.dart';
import 'package:prysm/ui/core/prysm_button.dart';
import 'package:prysm/ui/core/prysm_pressable.dart';
import 'package:prysm/util/notification_service.dart';
import 'package:prysm/util/conversation_refresh_notifier.dart';
import 'package:prysm/util/group_membership_notifier.dart';
import 'package:prysm/screens/widgets/add_contact_dialog.dart';
import 'package:prysm/screens/widgets/qr_scanner_screen.dart';
import 'package:prysm/screens/widgets/prysm_id_qr.dart';
import 'package:prysm/util/onion_id_codec.dart';
import 'package:prysm/util/decoy_session_data.dart';
import 'package:prysm/screens/decoy_chat_screen.dart';
import 'package:prysm/services/contact_add_service.dart';
import 'package:prysm/util/qr_platform.dart';
import 'package:prysm/util/tor_connection_notifier.dart';
import 'package:prysm/services/sync_coordinator.dart';
import 'package:prysm/services/wake_hint_service.dart';

class HomeScreen extends StatefulWidget {
  final TorManager torManager;
  final TorConnectionController torConnectionController;
  final String onionAddress;
  final KeyManager keyManager;
  final Function(int)? onThemeChanged;
  final VoidCallback? onAppearanceChanged;
  final int currentTheme;
  final bool decoyMode;
  final bool offlineMode;
  final bool torConnecting;
  final Future<void> Function() onConnectTor;

  const HomeScreen({
    required this.torManager,
    required this.torConnectionController,
    required this.onionAddress,
    required this.keyManager,
    required this.onConnectTor,
    this.onThemeChanged,
    this.onAppearanceChanged,
    this.currentTheme = 0,
    this.decoyMode = false,
    this.offlineMode = false,
    this.torConnecting = false,
    super.key,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  static final settings = SettingsService();
  final ConversationListRepository _conversationListRepository =
      const ConversationListRepository();

  List<Contact> contacts = [];
  List<Group> groups = [];
  List<Conversation> conversations = [];
  late Contact appUser;
  Contact? selectedContact;
  Conversation? selectedConversation;
  bool showProfile = false;
  bool showSettings = false;
  bool showSelfChat = false;
  int? _selfChatLastTimestamp;
  String? _selfChatLastPreview;
  bool isLoading = true;
  int currentTheme =
      0; // 0: Light, 1: Dark, 2: Pink, 3: Cyan, 4: Purple, 5 Orange
  String _searchQuery = '';
  final _searchController = TextEditingController();
  List<MessageSearchHit> _messageSearchResults = [];
  bool _messageSearchLoading = false;
  Timer? _messageSearchDebounce;
  String? _pendingScrollToMessageId;
  Map<String, String> _lastMessagePreviews = {};
  Map<String, int> _unreadCounts = {};
  Map<String, ConversationPreferences> _conversationPrefs = {};
  Map<String, List<DecoyMessage>> _decoyMessages = {};
  bool _viewingArchived = false;
  bool _viewingBlocked = false;
  bool _sidebarOpen = false;

  Timer? _refreshTimer;
  Timer? _loadUsersDebounce;
  StreamSubscription<void>? _batterySaverSub;
  StreamSubscription<void>? _inboundRefreshSub;
  StreamSubscription<String>? _groupMembershipSub;
  SyncCoordinator? _syncCoordinator;
  bool _loadUsersInProgress = false;
  bool _loadUsersQueued = false;
  bool _loadUsersQueuedLight = false;
  bool _sharePickerOpen = false;

  int get _archivedCount => conversations
      .where((c) => _conversationPrefs[c.id]?.isArchived ?? false)
      .length;

  int get _archivedUnreadCount => conversations
      .where(
        (c) =>
            (_conversationPrefs[c.id]?.isArchived ?? false) &&
            (_unreadCounts[c.id] ?? 0) > 0,
      )
      .length;

  int get _blockedCount => conversations
      .where(
        (c) => c is DirectConversation && BlockService.instance.isBlocked(c.id),
      )
      .length;

  int get _sidebarFooterCount {
    if (_viewingArchived || _viewingBlocked || _searchQuery.isNotEmpty) {
      return 0;
    }
    var count = 0;
    if (_archivedCount > 0) count++;
    if (_blockedCount > 0) count++;
    return count;
  }

  bool get _showMessageSearch =>
      _searchQuery.length >= 2 && !_viewingArchived && !_viewingBlocked;

  int get _sidebarSearchItemCount {
    if (!_showMessageSearch) {
      return _filteredConversations.length + _sidebarFooterCount;
    }
    var count = 0;
    if (_messageSearchLoading && _messageSearchResults.isEmpty) count++;
    if (_filteredConversations.isNotEmpty) {
      count += 1 + _filteredConversations.length;
    }
    if (_messageSearchResults.isNotEmpty) {
      count += 1 + _messageSearchResults.length;
    }
    return count;
  }

  void _scheduleMessageSearch(String query) {
    _messageSearchDebounce?.cancel();
    if (query.length < 2 || widget.decoyMode) {
      setState(() {
        _messageSearchResults = [];
        _messageSearchLoading = false;
      });
      return;
    }
    setState(() {
      _messageSearchResults = [];
      _messageSearchLoading = true;
    });
    _messageSearchDebounce = Timer(const Duration(milliseconds: 300), () async {
      final submitted = query;
      try {
        final hits = await MessagesDb.searchMessagesGlobal(submitted);
        if (!mounted || submitted != _searchQuery) return;
        final enriched = hits
            .where((h) => !BlockService.instance.isBlocked(h.conversationId))
            .map(
              (h) => h.copyWith(
                snippet: MessageSearchIndexService.buildSnippet(h.body, submitted),
              ),
            )
            .toList();
        setState(() {
          _messageSearchResults = enriched;
          _messageSearchLoading = false;
        });
      } catch (e) {
        if (!mounted || submitted != _searchQuery) return;
        setState(() {
          _messageSearchResults = [];
          _messageSearchLoading = false;
        });
      }
    });
  }

  String _conversationNameForHit(MessageSearchHit hit) {
    if (hit.scope == 'self') return 'Chat with myself';
    for (final conv in conversations) {
      if (conv.id == hit.conversationId) return conv.displayName;
    }
    return hit.conversationId;
  }

  String? _avatarForHit(MessageSearchHit hit) {
    for (final conv in conversations) {
      if (conv.id != hit.conversationId) continue;
      if (conv is DirectConversation) return conv.contact.avatarBase64;
      if (conv is GroupConversation) return conv.group.avatarBase64;
    }
    return null;
  }

  void _openMessageSearchResult(MessageSearchHit hit) {
    _pendingScrollToMessageId = null;
    if (hit.scope == 'self') {
      _pendingScrollToMessageId = hit.messageId;
      onSelectSelfChat();
      return;
    }
    if (hit.scope == 'group') {
      final group = groups.cast<Group?>().firstWhere(
            (g) => g?.id == hit.conversationId,
            orElse: () => null,
          );
      if (group != null) {
        _pendingScrollToMessageId = hit.messageId;
        onSelectGroup(group);
      }
      return;
    }
    final contact = contacts.cast<Contact?>().firstWhere(
          (c) => c?.id == hit.conversationId,
          orElse: () => null,
        );
    if (contact != null) {
      _pendingScrollToMessageId = hit.messageId;
      onSelectContact(contact);
    }
  }

  Widget _buildSearchSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: context.prysmStyle.tokens.textMuted,
        ),
      ),
    );
  }

  Widget _buildSearchSidebarItem(int index) {
    var cursor = 0;
    if (_messageSearchLoading && _messageSearchResults.isEmpty) {
      if (index == cursor) {
        return const Padding(
          padding: EdgeInsets.all(16),
          child: Center(child: PrysmProgressIndicator()),
        );
      }
      cursor++;
    }
    if (_filteredConversations.isNotEmpty) {
      if (index == cursor) return _buildSearchSectionHeader('Chats');
      cursor++;
      final chatIndex = index - cursor;
      if (chatIndex < _filteredConversations.length) {
        return _buildConversationRow(_filteredConversations[chatIndex]);
      }
      cursor += _filteredConversations.length;
    }
    if (_messageSearchResults.isNotEmpty) {
      if (index == cursor) return _buildSearchSectionHeader('Messages');
      cursor++;
      final messageIndex = index - cursor;
      if (messageIndex < _messageSearchResults.length) {
        final hit = _messageSearchResults[messageIndex];
        return MessageSearchResultRow(
          hit: hit,
          conversationName: _conversationNameForHit(hit),
          timeLabel: formatLastMessageTime(hit.timestamp),
          avatarBase64: _avatarForHit(hit),
          onTap: () => _openMessageSearchResult(hit),
        );
      }
    }
    return const SizedBox.shrink();
  }

  List<Conversation> get _filteredConversations {
    return conversations.where((c) {
      final blocked =
          c is DirectConversation && BlockService.instance.isBlocked(c.id);
      final archived = _conversationPrefs[c.id]?.isArchived ?? false;

      if (_viewingBlocked) {
        if (!blocked) return false;
        if (_searchQuery.isNotEmpty) {
          final name = c.contact.displayName.toLowerCase();
          return name.contains(_searchQuery) ||
              c.id.toLowerCase().contains(_searchQuery);
        }
        return true;
      }

      if (blocked) return false;

      if (_searchQuery.isNotEmpty) {
        if (!c.displayName.toLowerCase().contains(_searchQuery)) return false;
        return _viewingArchived ? archived : true;
      }
      return _viewingArchived ? archived : !archived;
    }).toList();
  }

  Future<void> _reloadConversationPreferences() async {
    if (widget.decoyMode) return;
    final prefs = await ConversationPreferencesService.instance.getAll();
    if (!mounted) return;
    setState(() {
      _conversationPrefs = prefs;
      ConversationPreferencesService.sortConversations(conversations, prefs);
    });
  }

  void _updateDecoyConversationPref(ConversationPreferences pref) {
    setState(() {
      _conversationPrefs = Map.of(_conversationPrefs)
        ..[pref.conversationId] = pref;
      ConversationPreferencesService.sortConversations(
        conversations,
        _conversationPrefs,
      );
    });
  }

  Future<void> _pinConversation(String id) async {
    if (widget.decoyMode) {
      _updateDecoyConversationPref(
        ConversationPreferences(
          conversationId: id,
          isPinned: true,
          pinnedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      return;
    }
    await ConversationPreferencesService.instance.pin(id);
    await _reloadConversationPreferences();
  }

  Future<void> _unpinConversation(String id) async {
    if (widget.decoyMode) {
      _updateDecoyConversationPref(ConversationPreferences(conversationId: id));
      return;
    }
    await ConversationPreferencesService.instance.unpin(id);
    await _reloadConversationPreferences();
  }

  Future<void> _archiveConversation(String id) async {
    if (widget.decoyMode) {
      _updateDecoyConversationPref(
        ConversationPreferences(
          conversationId: id,
          isArchived: true,
          archivedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      if (selectedConversation?.id == id) {
        clearChat();
      }
      if (mounted) {
        setState(() => _viewingArchived = false);
      }
      return;
    }
    await ConversationPreferencesService.instance.archive(id);
    if (selectedConversation?.id == id) {
      clearChat();
    }
    if (mounted) {
      setState(() => _viewingArchived = false);
    }
    await _reloadConversationPreferences();
  }

  Future<void> _unarchiveConversation(String id) async {
    if (widget.decoyMode) {
      _updateDecoyConversationPref(ConversationPreferences(conversationId: id));
      return;
    }
    await ConversationPreferencesService.instance.unarchive(id);
    await _reloadConversationPreferences();
  }

  void _showConversationActions(Conversation conv) {
    showConversationActionsSheet(
      context: context,
      conversation: conv,
      preferences: _conversationPrefs[conv.id],
      viewingArchived: _viewingArchived,
      onPin: () => _pinConversation(conv.id),
      onUnpin: () => _unpinConversation(conv.id),
      onArchive: () => _archiveConversation(conv.id),
      onUnarchive: () => _unarchiveConversation(conv.id),
    );
  }

  void _wireOnlineServices() {
    if (widget.decoyMode || widget.offlineMode) return;

    AppComposition.wireOnlineServices(
      torManager: widget.torManager,
      syncCoordinator: _syncCoordinator!,
      onionAddress: widget.onionAddress,
      isTorStopped: () => widget.torConnectionController.torStopped,
    );
    widget.torConnectionController.startMonitoring(decoyMode: widget.decoyMode);
  }

  @override
  void didUpdateWidget(HomeScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.offlineMode && !widget.offlineMode) {
      _wireOnlineServices();
      unawaited(loadUsers());
    }
    if (oldWidget.currentTheme != widget.currentTheme) {
      setState(() {
        currentTheme = widget.currentTheme;
      });
    }
  }

  void _onTorControllerChanged() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    currentTheme = widget.currentTheme;
    final appSettings = SettingsService();
    widget.torConnectionController
      ..onReconnected = _onTorReconnected
      ..onRestartSucceeded = () {
        if (mounted) showPrysmToast(context, 'Tor restarted successfully');
      }
      ..onRestartFailed = (e) {
        if (mounted) showPrysmToast(context, 'Tor restart failed: $e');
      }
      ..addListener(_onTorControllerChanged);
    if (widget.decoyMode) {
      _bootstrapDecoySession();
    } else {
      appUser = Contact(
        id: widget.onionAddress,
        name: appSettings.username ?? '',
        avatarUrl: '',
        identityJson: 'NONE',
      );
    }
    if (widget.offlineMode) {
      widget.torConnectionController.markStoppedForOfflineMode();
    }
    _syncCoordinator = AppComposition.createSyncCoordinator(
      userId: widget.decoyMode ? 'decoy-user' : widget.onionAddress,
      keyManager: widget.keyManager,
      torManager: widget.torManager,
      isTorStopped: () => widget.torConnectionController.torStopped,
    );
    if (!widget.decoyMode && !widget.offlineMode) {
      _wireOnlineServices();
    } else if (!widget.decoyMode) {
      AppComposition.wireTorRuntimeGate(
        () => widget.torConnectionController.torStopped,
      );
    }

    if (widget.decoyMode) {
      return;
    }

    loadUsers()
        .then((_) async {
          if (mounted && !widget.torConnectionController.torStopped) {
            final flushed = await _syncCoordinator!.flushAllPending();
            if (flushed && mounted) {
              scheduleLoadUsers(light: true);
            }
            if (mounted) {
              unawaited(_maybeBroadcastWakeHints(coldStart: true));
            }
          }
        })
        .catchError((Object e, StackTrace st) {
          Logging.error('loadUsers failed: $e\n$st', 'Main');
        });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(AppUpdateService().checkOnStartup(context));
    });

    _startAutoRefresh();
    if (!widget.offlineMode) {
      widget.torConnectionController.startHealthMonitor();
    }
    _batterySaverSub = BatterySaverService.instance.onChanged.listen((_) {
      if (!mounted) return;
      _restartBackgroundIntervals();
    });
    _inboundRefreshSub = ConversationRefreshNotifier.instance.onRefresh.listen((
      _,
    ) {
      scheduleLoadUsers(light: true);
    });
    _groupMembershipSub = GroupMembershipNotifier.instance.onRemoved.listen((
      groupId,
    ) {
      if (!mounted) return;
      if (selectedConversation is GroupConversation &&
          (selectedConversation as GroupConversation).group.id == groupId) {
        clearChat();
      }
      scheduleLoadUsers(light: true);
    });
    NotificationService.onNotificationTap = _handleNotificationTap;
    NotificationService.onCallNotificationTap = _handleCallNotificationAction;
    ShareIntentService.instance.onPendingShare = _handlePendingShareIntent;

    if (!Platform.isAndroid && !Platform.isIOS) {
      unawaited(TrayService.instance.start(userId: widget.onionAddress));
      _configureDetachedChat();
    }

    if (!widget.decoyMode) {
      AppComposition.startSearchBackfill(
        keyManager: widget.keyManager,
        userId: widget.onionAddress,
      );
    }
  }

  void _configureDetachedChat() {
    if (!isDesktopPlatform || widget.decoyMode || widget.offlineMode) {
      DetachedChatWindowRegistry.instance.setCanOpen(false);
      return;
    }
    DetachedChatWindowRegistry.instance.setCanOpen(true);
    DetachedChatBridge.configure(
      keyManager: widget.keyManager,
      userId: widget.onionAddress,
      appUser: () => appUser,
      contacts: () => contacts,
      groupById: (groupId) {
        try {
          return groups.firstWhere((g) => g.id == groupId);
        } catch (_) {
          return null;
        }
      },
    );
    unawaited(DetachedChatHost.instance.start());
  }

  bool get _canOpenDetachedChat =>
      isDesktopPlatform &&
      !widget.decoyMode &&
      !widget.offlineMode &&
      !widget.torConnectionController.torStopped &&
      TransportProvider.isConfigured;

  Future<void> _openDetachedFromConversation(Conversation conv) async {
    if (!_canOpenDetachedChat) return;

    final launch = switch (conv) {
      DirectConversation(:final contact) => DetachedChatLaunch.detached(
        chatKind: DetachedChatKind.direct,
        conversationId: contact.id,
        title: contact.displayName,
        userId: appUser.id,
        userName: appUser.name,
        avatarBase64: contact.avatarBase64,
        peerPublicKeyPem: contact.publicKeyPem,
        themeIndex: currentTheme,
      ),
      GroupConversation(:final group) => DetachedChatLaunch.detached(
        chatKind: DetachedChatKind.group,
        conversationId: group.id,
        title: group.name,
        userId: appUser.id,
        userName: appUser.name,
        avatarBase64: group.avatarBase64,
        themeIndex: currentTheme,
      ),
      SelfConversation() => throw UnsupportedError(
        'Self chat uses dedicated handler',
      ),
    };

    try {
      await DetachedChatWindowRegistry.instance.openOrFocus(launch);
    } catch (e) {
      if (!mounted) return;
      showPrysmToast(context, 'Could not open separate window: $e');
    }
  }

  Future<void> _openDetachedSelfChat() async {
    if (!_canOpenDetachedChat) return;
    final launch = DetachedChatLaunch.detached(
      chatKind: DetachedChatKind.self,
      conversationId: DetachedChatLaunch.selfConversationId,
      title: 'Chat with myself',
      userId: appUser.id,
      userName: appUser.name,
      avatarBase64: appUser.avatarBase64,
      themeIndex: currentTheme,
    );
    try {
      await DetachedChatWindowRegistry.instance.openOrFocus(launch);
    } catch (e) {
      if (!mounted) return;
      showPrysmToast(context, 'Could not open separate window: $e');
    }
  }

  void _showConversationContextMenu(Offset position, Conversation conv) {
    showConversationContextMenu(
      context: context,
      position: position,
      conversation: conv,
      preferences: _conversationPrefs[conv.id],
      viewingArchived: _viewingArchived,
      canOpenDetached: _canOpenDetachedChat,
      onOpenDetached: () => _openDetachedFromConversation(conv),
      onPin: () => _pinConversation(conv.id),
      onUnpin: () => _unpinConversation(conv.id),
      onArchive: () => _archiveConversation(conv.id),
      onUnarchive: () => _unarchiveConversation(conv.id),
    );
  }

  void scheduleLoadUsers({bool light = false}) {
    _loadUsersQueuedLight = _loadUsersQueuedLight || light;
    _loadUsersDebounce?.cancel();
    _loadUsersDebounce = Timer(BatterySaverPolicy.loadUsersDebounce(), () {
      if (!mounted) return;
      final lightOnly = _loadUsersQueuedLight;
      _loadUsersQueuedLight = false;
      unawaited(loadUsers(light: lightOnly));
    });
  }

  void _handleNotificationTap(String? payload) {
    unawaited(_openChatFromNotificationPayload(payload));
  }

  void _handleCallNotificationAction(PendingCallAction action) {
    unawaited(_processCallNotificationAction(action));
  }

  Future<void> _processCallNotificationAction(PendingCallAction action) async {
    if (widget.decoyMode) return;
    if (!mounted) {
      PendingCallActionStore.instance.set(action);
      return;
    }

    try {
      CallManager.instance;
    } catch (_) {
      PendingCallActionStore.instance.set(action);
      return;
    }

    try {
      switch (action.action) {
        case CallNotificationAction.accept:
          if (CallManager.instance.snapshot.state != CallState.incoming) break;
          await NotificationService().cancelCallNotifications();
          await CallManager.instance.acceptIncoming();
        case CallNotificationAction.decline:
          await NotificationService().cancelCallNotifications();
          await CallManager.instance.declineFromNotification(
            callId: action.callId,
            peerOnion: action.peerOnion,
          );
        case CallNotificationAction.hangup:
          if (!CallManager.instance.snapshot.isInCall) break;
          await NotificationService().cancelCallNotifications();
          await CallManager.instance.endCall();
        case CallNotificationAction.open:
          break;
      }
    } finally {
      PendingCallActionStore.instance.clear();
    }
  }

  Future<void> _consumePendingCallAction() async {
    final action = PendingCallActionStore.instance.take();
    if (action == null) return;
    await _processCallNotificationAction(action);
  }

  Future<void> _openChatFromNotificationPayload(String? payload) async {
    if (widget.decoyMode || !mounted) return;

    final route = payload != null
        ? PendingNotificationRoute.fromPayload(payload)
        : PendingNotificationRouteStore.instance.take();
    if (payload != null) {
      PendingNotificationRouteStore.instance.clear();
    }
    if (route == null) return;

    if (route.isGroup) {
      final group = await NotificationOpenChatResolver.resolveGroup(
        groups: groups,
        groupId: route.groupId!,
      );
      if (!mounted || group == null) return;
      onSelectGroup(group);
      await NotificationService().cancelConversationNotification(
        groupId: route.groupId,
        senderId: route.senderId,
      );
      _closeMobileDrawerIfOpen();
      return;
    }

    final contact = await NotificationOpenChatResolver.resolveContact(
      contacts: contacts,
      senderId: route.senderId,
    );
    if (!mounted || contact == null) return;
    onSelectContact(contact);
    await NotificationService().cancelConversationNotification(
      senderId: route.senderId,
    );
    _closeMobileDrawerIfOpen();
  }

  Future<void> _consumePendingNotificationRoute() async {
    if (PendingNotificationRouteStore.instance.peek() == null) return;
    await _openChatFromNotificationPayload(null);
  }

  void _handlePendingShareIntent() {
    if (!mounted || widget.decoyMode) return;
    unawaited(_consumePendingShare());
  }

  List<Conversation> get _shareableConversations {
    return conversations.where((conversation) {
      if (conversation is DirectConversation &&
          BlockService.instance.isBlocked(conversation.id)) {
        return false;
      }
      return !(_conversationPrefs[conversation.id]?.isArchived ?? false);
    }).toList();
  }

  Group? _groupById(String groupId) {
    try {
      return groups.firstWhere((group) => group.id == groupId);
    } catch (_) {
      return null;
    }
  }

  void _openChatFromShareTarget(ShareTarget target) {
    switch (target.kind) {
      case DetachedChatKind.direct:
        final contact = contacts.cast<Contact?>().firstWhere(
          (c) => c?.id == target.conversationId,
          orElse: () => null,
        );
        if (contact != null) onSelectContact(contact);
      case DetachedChatKind.group:
        final group = _groupById(target.conversationId);
        if (group != null) onSelectGroup(group);
      case DetachedChatKind.self:
        onSelectSelfChat();
    }
  }

  Future<void> _consumePendingShare() async {
    if (widget.decoyMode || !mounted || _sharePickerOpen) return;
    final content = PendingShareStore.instance.peek();
    if (content == null) return;

    _sharePickerOpen = true;
    final target = await Navigator.of(context).push<ShareTarget>(
      PrysmPageRoute(
        page: ShareTargetPickerScreen(
          content: content,
          conversations: _shareableConversations,
          userId: appUser.id,
          userName: appUser.name,
          userAvatarBase64: appUser.avatarBase64,
          contacts: contacts,
          keyManager: widget.keyManager,
          groupById: _groupById,
        ),
      ),
    );
    _sharePickerOpen = false;

    if (!mounted) return;
    if (target != null) {
      _openChatFromShareTarget(target);
      scheduleLoadUsers(light: true);
    }
  }

  void _closeMobileDrawerIfOpen() {
    if (!mounted) return;
    if (MediaQuery.of(context).size.width >= 600) return;
    if (_sidebarOpen) {
      setState(() => _sidebarOpen = false);
    }
  }

  void _dismissConversationNotification({
    String? groupId,
    required String senderId,
  }) {
    unawaited(
      NotificationService().cancelConversationNotification(
        groupId: groupId,
        senderId: senderId,
      ),
    );
  }

  void _syncActiveConversationTracker() {
    if (widget.decoyMode) {
      ActiveConversationTracker.instance.clear();
      return;
    }
    final selected = selectedConversation;
    if (selected is DirectConversation) {
      ActiveConversationTracker.instance.setDirect(selected.contact.id);
      return;
    }
    if (selected is GroupConversation) {
      ActiveConversationTracker.instance.setGroup(selected.group.id);
      return;
    }
    ActiveConversationTracker.instance.clear();
  }

  void _restartBackgroundIntervals() {
    _refreshTimer?.cancel();
    _startAutoRefresh();
    if (!widget.offlineMode) {
      widget.torConnectionController.startHealthMonitor();
    }
    _syncCoordinator?.start();
  }

  void _startAutoRefresh() {
    _refreshTimer?.cancel();
    _refreshTimer = Timer.periodic(BatterySaverPolicy.homeRefreshInterval(), (
      timer,
    ) async {
      if (!mounted || widget.torConnectionController.torStopped) return;
      await loadUsers();
      if (!mounted || widget.torConnectionController.torStopped) return;
      await _flushPendingIfReachable();
    });
  }

  Future<void> _flushPendingIfReachable() async {
    if (!mounted || widget.torConnectionController.torStopped) return;
    final flushed = await _syncCoordinator?.flushAllPending() ?? false;
    if (flushed && mounted) {
      scheduleLoadUsers(light: true);
    }
  }

  Future<void> loadUsers({bool light = false}) async {
    if (!mounted || widget.decoyMode) return;
    if (_loadUsersInProgress) {
      _loadUsersQueued = true;
      _loadUsersQueuedLight = _loadUsersQueuedLight || light;
      return;
    }
    _loadUsersInProgress = true;

    try {
      final groupService = GroupService(
        userId: widget.onionAddress,
        keyManager: widget.keyManager,
      );
      await groupService.pruneOrphanedGroups();
      await groupService.discardPendingHistoryRelay();

      late final List<Map<String, dynamic>> userMaps;
      late final Map<String, int> timestamps;
      late final List<Group> newGroups;
      late final Map<String, ConversationPreferences> prefs;
      Map<String, String> previews = _lastMessagePreviews;
      Map<String, int> unread = _unreadCounts;

      if (light) {
        final results = await Future.wait([
          _conversationListRepository.getUsers(),
          _conversationListRepository.getLastMessageTimestampsForAllUsers(),
          groupService.getGroups(),
          _conversationListRepository.getLastMessagePreviews(widget.onionAddress),
          _conversationListRepository.getUnreadCounts(widget.onionAddress),
          _conversationListRepository.getConversationPreferences(),
          _conversationListRepository.getSelfChatLastTimestamp(),
          _conversationListRepository.getSelfChatLastPreview(),
        ]);
        if (!mounted) return;
        userMaps = results[0] as List<Map<String, dynamic>>;
        timestamps = results[1] as Map<String, int>;
        newGroups = results[2] as List<Group>;
        previews = results[3] as Map<String, String>;
        unread = results[4] as Map<String, int>;
        prefs = results[5] as Map<String, ConversationPreferences>;
        _selfChatLastTimestamp = results[6] as int?;
        _selfChatLastPreview = results[7] as String?;
      } else {
        final fastResults = await Future.wait([
          _conversationListRepository.getUsers(),
          _conversationListRepository.getLastMessageTimestampsForAllUsers(),
          groupService.getGroups(),
          _conversationListRepository.getConversationPreferences(),
        ]);
        if (!mounted) return;
        userMaps = fastResults[0] as List<Map<String, dynamic>>;
        timestamps = fastResults[1] as Map<String, int>;
        newGroups = fastResults[2] as List<Group>;
        prefs = fastResults[3] as Map<String, ConversationPreferences>;

        if (isLoading) {
          _applyLoadedUsers(
            userMaps: userMaps,
            timestamps: timestamps,
            newGroups: newGroups,
            previews: previews,
            unread: unread,
            prefs: prefs,
          );
        }

        final deferred = await Future.wait([
          _conversationListRepository.getLastMessagePreviews(widget.onionAddress),
          _conversationListRepository.getUnreadCounts(widget.onionAddress),
          _conversationListRepository.getSelfChatLastTimestamp(),
          _conversationListRepository.getSelfChatLastPreview(),
        ]);
        if (!mounted) return;
        previews = deferred[0] as Map<String, String>;
        unread = deferred[1] as Map<String, int>;
        _selfChatLastTimestamp = deferred[2] as int?;
        _selfChatLastPreview = deferred[3] as String?;
      }

      _applyLoadedUsers(
        userMaps: userMaps,
        timestamps: timestamps,
        newGroups: newGroups,
        previews: previews,
        unread: unread,
        prefs: prefs,
      );
    } finally {
      _loadUsersInProgress = false;
      if (_loadUsersQueued && mounted) {
        _loadUsersQueued = false;
        final queuedLight = _loadUsersQueuedLight;
        _loadUsersQueuedLight = false;
        scheduleLoadUsers(light: queuedLight);
      }
    }
  }

  void _applyLoadedUsers({
    required List<Map<String, dynamic>> userMaps,
    required Map<String, int> timestamps,
    required List<Group> newGroups,
    required Map<String, String> previews,
    required Map<String, int> unread,
    required Map<String, ConversationPreferences> prefs,
  }) {
    if (!mounted) return;

    final newContacts = <Contact>[];
    for (var map in userMaps) {
      final id = map['id'] as String;
      newContacts.add(
        Contact(
          id: id,
          name: map['name'] as String,
          avatarUrl: '',
          avatarBase64: map['avatarBase64'] as String?,
          customName: map['customName'] as String?,
          identityJson:
              (map['identityJson'] as String?) ??
              (map['publicKeyPem'] as String?) ??
              '',
          lastMessageTimestamp: timestamps[id],
        ),
      );
    }

    Contact? newAppUser;
    try {
      newAppUser = newContacts.firstWhere((c) => c.id == widget.onionAddress);
    } catch (_) {
      saveAppUser(appUser);
    }

    if (newAppUser != null) {
      final s = SettingsService();
      if (s.username == null &&
          newAppUser.name.isNotEmpty &&
          newAppUser.name != 'My Profile') {
        s.setUsername(newAppUser.name);
      }
      if (s.avatar == null && newAppUser.avatarBase64 != null) {
        s.setAvatar(newAppUser.avatarBase64);
      }
    }

    final newConversations = <Conversation>[
      ...newContacts
          .where((c) => c.id != widget.onionAddress)
          .map((c) => DirectConversation(c)),
      ...newGroups.map((g) => GroupConversation(g)),
    ];
    ConversationPreferencesService.sortConversations(newConversations, prefs);

    final changed =
        newContacts.length != contacts.length ||
        newGroups.length != groups.length ||
        !_mapsEqual(previews, _lastMessagePreviews) ||
        !_mapsEqual(unread, _unreadCounts) ||
        !_conversationPrefsEqual(prefs, _conversationPrefs) ||
        !newConversations.every((c) {
          final old = conversations.cast<Conversation?>().firstWhere(
            (o) => o!.id == c.id,
            orElse: () => null,
          );
          return old != null &&
              old.displayName == c.displayName &&
              formatLastMessageTime(old.lastMessageTimestamp) ==
                  formatLastMessageTime(c.lastMessageTimestamp);
        });

    if (changed) {
      setState(() {
        _lastMessagePreviews = previews;
        _unreadCounts = unread;
        _conversationPrefs = prefs;
        contacts = newContacts;
        groups = newGroups;
        conversations = newConversations;
        if (newAppUser != null) {
          appUser = newAppUser;
        }
        if (selectedConversation != null) {
          if (selectedConversation is DirectConversation) {
            final id = (selectedConversation as DirectConversation).contact.id;
            selectedContact = contacts.cast<Contact?>().firstWhere(
              (c) => c?.id == id,
              orElse: () => null,
            );
          } else if (selectedConversation is GroupConversation) {
            final id = (selectedConversation as GroupConversation).group.id;
            final g = groups.cast<Group?>().firstWhere(
              (gr) => gr?.id == id,
              orElse: () => null,
            );
            if (g == null) {
              selectedConversation = null;
            } else {
              selectedConversation = GroupConversation(g);
            }
          }
        }
        isLoading = false;
      });
    } else if (isLoading) {
      setState(() => isLoading = false);
    }

    _syncActiveConversationTracker();
    unawaited(_consumePendingNotificationRoute());
    unawaited(_consumePendingCallAction());
    unawaited(_consumePendingShare());
  }

  bool _mapsEqual<K, V>(Map<K, V> a, Map<K, V> b) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (b[entry.key] != entry.value) return false;
    }
    return true;
  }

  bool _conversationPrefsEqual(
    Map<String, ConversationPreferences> a,
    Map<String, ConversationPreferences> b,
  ) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      final other = b[entry.key];
      if (other == null || other != entry.value) return false;
    }
    return true;
  }

  void saveAppUser(Contact user) async {
    await DBHelper.insertOrUpdateUser({
      'id': user.id,
      'name': user.name,
      'avatarUrl': user.avatarUrl,
      'avatarBase64': user.avatarBase64,
      'publicKeyPem': user.publicKeyPem,
    });
  }

  void _bootstrapDecoySession() {
    final data = DecoySessionData.build();
    appUser = data.appUser;
    contacts = data.contacts;
    groups = data.groups;
    conversations = data.conversations;
    _lastMessagePreviews = data.lastMessagePreviews;
    _unreadCounts = data.unreadCounts;
    _conversationPrefs = data.conversationPrefs;
    _decoyMessages = data.messagesByConversationId;
    isLoading = false;
  }

  void onUpdateProfile(Contact updatedUser) {
    setState(() {
      appUser = updatedUser;
    });
    if (widget.decoyMode) return;
    saveAppUser(updatedUser);
    // Persist avatar and username to SettingsService so /profile serves fresh data
    final settings = SettingsService();
    settings.setAvatar(updatedUser.avatarBase64);
    settings.setUsername(updatedUser.name);
    loadUsers();
  }

  void onSelectContact(Contact contact) {
    setState(() {
      selectedContact = contact;
      selectedConversation = DirectConversation(contact);
      showProfile = false;
      showSettings = false;
      showSelfChat = false;
    });
    _closeMobileDrawerIfOpen();
    _syncActiveConversationTracker();
    _dismissConversationNotification(senderId: contact.id);
  }

  void onSelectGroup(Group group) {
    setState(() {
      selectedContact = null;
      selectedConversation = GroupConversation(group);
      showProfile = false;
      showSettings = false;
      showSelfChat = false;
    });
    _closeMobileDrawerIfOpen();
    _syncActiveConversationTracker();
    _dismissConversationNotification(groupId: group.id, senderId: group.id);
  }

  void _showCreateGroup() {
    if (widget.decoyMode) {
      showPrysmToast(context, 
            'Could not create group. Make sure all members are online and try again.',
          );
      return;
    }
    Navigator.of(context).push(
      PrysmPageRoute(page: CreateGroupScreen(
          userId: widget.onionAddress,
          contacts: contacts,
          keyManager: widget.keyManager,
          onGroupCreated: (group) {
            loadUsers();
            onSelectGroup(group);
          },
        ),
      ),
    );
  }

  void onSelectSelfChat() {
    setState(() {
      showSelfChat = true;
      selectedContact = null;
      selectedConversation = SelfConversation(_selfChatLastTimestamp);
      showProfile = false;
      showSettings = false;
    });
    _closeMobileDrawerIfOpen();
  }

  void onShowProfile() {
    setState(() {
      showSettings = false;
      showProfile = true;
      showSelfChat = false;
    });
  }

  void onShowSettings() {
    setState(() {
      showSettings = true;
      showProfile = false;
      showSelfChat = false;
    });
  }

  void onThemeChanged(int themeIndex) {
    setState(() {
      currentTheme = themeIndex;
    });
    widget.onThemeChanged?.call(themeIndex);
  }

  void onAppearanceChanged() {
    widget.onAppearanceChanged?.call();
  }

  bool _isEditableFocused() {
    final ctx = FocusManager.instance.primaryFocus?.context;
    return ctx?.widget is EditableText;
  }

  Map<ShortcutActivator, VoidCallback> _desktopShortcut(
    LogicalKeyboardKey key,
    VoidCallback action,
  ) {
    if (!isDesktopPlatform) return {};
    void invoke() {
      if (_isEditableFocused()) return;
      action();
    }

    return {
      SingleActivator(key, control: true): invoke,
      if (Platform.isMacOS) SingleActivator(key, meta: true): invoke,
    };
  }

  String _desktopShortcutTooltip(String label, String key) {
    if (!isDesktopPlatform) return label;
    final mod = Platform.isMacOS ? 'Cmd' : 'Ctrl';
    return '$label ($mod+$key)';
  }

  Widget _tooltipIconButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback? onPressed,
  }) {
    return Semantics(
      label: tooltip,
      button: true,
      child: PrysmIconButton(
        icon: icon,
        onPressed: onPressed,
      ),
    );
  }

  Future<void> _showAddUserDialog({String? prefilledId}) async {
    if (widget.offlineMode) {
      showPrysmToast(context, 'Connect to Tor before adding contacts');
      return;
    }

    final hostContext = context;

    await showAddContactDialog(
      context: hostContext,
      prefilledId: prefilledId,
      decoyMode: widget.decoyMode,
      onAdd: (onionId, displayName, {expectedFingerprint}) async {
        final added = await _addNewUser(
          onionId,
          displayName,
          expectedFingerprint: expectedFingerprint,
        );
        if (added) unawaited(loadUsers());
        return added;
      },
      onScanQr: () async {
        Navigator.of(hostContext).pop();
        final scannedValue = await Navigator.push<String>(
          hostContext,
          PrysmPageRoute(page: const QrScannerScreen()),
        );
        if (scannedValue != null && scannedValue.isNotEmpty) {
          _showAddUserDialog(prefilledId: scannedValue);
        }
      },
    );
  }

  Future<bool> _addNewUser(
    String id,
    String name, {
    String? expectedFingerprint,
  }) async {
    return ContactAddService.instance.addContact(
      onionId: id,
      displayName: name,
      expectedFingerprint: expectedFingerprint,
    );
  }

  bool get _showSelfChatInSidebar {
    if (widget.decoyMode || _viewingArchived || _viewingBlocked) return false;
    if (_searchQuery.isEmpty) return true;
    return 'chat with myself'.contains(_searchQuery);
  }

  Widget _buildSelfChatSidebarTile() {
    final timeLabel = formatLastMessageTime(_selfChatLastTimestamp);
    final preview = _selfChatLastPreview;
    final subtitle = preview != null ? '$preview · $timeLabel' : timeLabel;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: GestureDetector(
        onSecondaryTapDown: isDesktopPlatform
            ? (details) => showConversationContextMenu(
                context: context,
                position: details.globalPosition,
                conversation: SelfConversation(_selfChatLastTimestamp),
                preferences: null,
                viewingArchived: false,
                canOpenDetached: _canOpenDetachedChat,
                showPinArchive: false,
                onOpenDetached: _openDetachedSelfChat,
              )
            : null,
        child: PrysmListRow(
          selected: showSelfChat,
          leading: ContactAvatar(
            name: appUser.name,
            avatarBase64: appUser.avatarBase64,
          ),
          title: 'Chat with myself',
          subtitle: subtitle,
          onTap: onSelectSelfChat,
        ),
      ),
    );
  }

  Widget _buildConversationRow(Conversation conv) {
    final tokens = context.prysmStyle.tokens;
    final isSelected = selectedConversation?.id == conv.id;
    final prefs = _conversationPrefs[conv.id];
    final isPinned = prefs?.isPinned ?? false;
    final Widget leading;
    final String subtitle;

    final unreadCount = _unreadCounts[conv.id] ?? 0;
    final preview = _lastMessagePreviews[conv.id];
    final timeLabel = formatLastMessageTime(conv.lastMessageTimestamp);

    if (conv is DirectConversation) {
      final contact = conv.contact;
      final isBlockedContact = BlockService.instance.isBlocked(conv.id);
      leading = ContactAvatar(
        name: contact.displayName,
        avatarBase64: contact.avatarBase64,
      );
      if (isBlockedContact) {
        subtitle = timeLabel;
      } else {
        subtitle = preview != null ? '$preview · $timeLabel' : timeLabel;
      }
    } else {
      final group = (conv as GroupConversation).group;
      leading = ContactAvatar(
        name: group.name,
        avatarBase64: group.avatarBase64,
      );
      subtitle = preview != null
          ? 'Group · $preview · $timeLabel'
          : 'Group · $timeLabel';
    }

    final isBlockedContact =
        conv is DirectConversation && BlockService.instance.isBlocked(conv.id);

    return GestureDetector(
      key: ValueKey(
        '${conv.id}_${conv.lastMessageTimestamp ?? 0}_$unreadCount',
      ),
      onSecondaryTapDown: isDesktopPlatform
          ? (details) =>
              _showConversationContextMenu(details.globalPosition, conv)
          : null,
      onLongPress: () => _showConversationActions(conv),
      child: PrysmListRow(
        selected: isSelected,
        onTap: () {
          if (conv is DirectConversation) {
            onSelectContact(conv.contact);
          } else if (conv is GroupConversation) {
            onSelectGroup(conv.group);
          }
        },
        leading: SizedBox(width: 48, height: 48, child: leading),
        title: conv.displayName,
        subtitle: subtitle,
        trailingSubtitle:
            timeLabel.contains(' · ') ? timeLabel.split(' · ').last : timeLabel,
        trailing: unreadCount > 0 && !isBlockedContact
            ? PrysmUnreadBadge(count: unreadCount)
            : isBlockedContact && _viewingBlocked
                ? Icon(PrysmIcons.block, size: 18, color: tokens.textMuted)
                : isPinned && !_viewingArchived && !_viewingBlocked
                    ? Icon(PrysmIcons.pushPin,
                        size: 16, color: tokens.textMuted)
                    : null,
      ),
    );
  }

  String formatLastMessageTime(int? timestamp) {
    if (timestamp == null) return "No message";
    final dt = DateTime.fromMillisecondsSinceEpoch(timestamp).toUtc().toLocal();
    final now = DateTime.now().toUtc();

    bool isSameDay =
        dt.year == now.year && dt.month == now.month && dt.day == now.day;

    if (isSameDay) {
      final h = dt.hour.toString().padLeft(2, '0');
      final m = dt.minute.toString().padLeft(2, '0');
      return '$h:$m';
    } else {
      final d = dt.day.toString().padLeft(2, '0');
      final mo = dt.month.toString().padLeft(2, '0');
      final y = (dt.year % 100).toString().padLeft(2, '0');
      final h = dt.hour.toString().padLeft(2, '0');
      final min = dt.minute.toString().padLeft(2, '0');
      return '$d/$mo/$y - $h:$min';
    }
  }

  Widget buildSidebar() {
    final isMobile =
        MediaQuery.of(context).size.width < 600;
    final tokens = context.prysmTokens;
    final safePadding = MediaQuery.paddingOf(context);

    return Container(
      margin: EdgeInsets.only(
        top: isMobile ? safePadding.top : 0,
        bottom: isMobile ? safePadding.bottom : 0,
      ),
      width: 320,
      decoration: BoxDecoration(
        color: tokens.sidebar,
        border: Border(
          right: BorderSide(color: tokens.divider, width: 1),
        ),
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: context.prysmStyle.tokens.divider.withValues(alpha: 0.1),
                  width: 1,
                ),
              ),
            ),
            child: Row(
              children: [
                ContactAvatar(
                  name: appUser.name,
                  radius: 20,
                  avatarBase64: appUser.avatarBase64,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        appUser.name,
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _onionPreview(widget.onionAddress),
                        style: TextStyle(
                          fontSize: 12,
                          color: context.prysmStyle.tokens.textMuted,
                        ),
                      ),
                    ],
                  ),
                ),
                _tooltipIconButton(
                  icon: PrysmIcons.qrCode,
                  tooltip: 'Show my QR code',
                  onPressed: () {
                    String? fingerprint;
                    try {
                      final parsed =
                          jsonDecode(widget.keyManager.publicKeyJson)
                              as Map<String, dynamic>;
                      fingerprint = parsed['fingerprint'] as String?;
                    } catch (_) {}
                    showPrysmIdQrDialog(
                      context,
                      encodeOnionToBase58(appUser.id),
                      fingerprint: fingerprint,
                    );
                  },
                ),
                if (QrPlatform.isScanSupported)
                  _tooltipIconButton(
                    icon: PrysmIcons.qrCodeScanner,
                    tooltip: 'Scan a QR code',
                    onPressed: () async {
                      final scanned = await Navigator.push<String>(
                        context,
                        PrysmPageRoute(page: const QrScannerScreen()),
                      );
                      if (scanned != null && scanned.isNotEmpty) {
                        _showAddUserDialog(prefilledId: scanned);
                      }
                    },
                  ),
              ],
            ),
          ),
          if (_viewingArchived)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                children: [
                  _tooltipIconButton(
                    icon: PrysmIcons.arrowBack,
                    tooltip: 'Back to chats',
                    onPressed: () => setState(() {
                      _viewingArchived = false;
                      _searchQuery = '';
                      _searchController.clear();
                    }),
                  ),
                  const Expanded(
                    child: Text(
                      'Archived',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 16,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          if (_viewingBlocked)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                children: [
                  _tooltipIconButton(
                    icon: PrysmIcons.arrowBack,
                    tooltip: 'Back to chats',
                    onPressed: () => setState(() {
                      _viewingBlocked = false;
                      _searchQuery = '';
                      _searchController.clear();
                    }),
                  ),
                  const Expanded(
                    child: Text(
                      'Blocked',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 16,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 8),
          // Search bar
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: PrysmSearchField(
              controller: _searchController,
              hintText: _viewingArchived
                  ? 'Search archived...'
                  : _viewingBlocked
                      ? 'Search blocked...'
                      : 'Search chats and messages...',
              onChanged: (value) {
                final query = value.trim().toLowerCase();
                setState(() => _searchQuery = query);
                _scheduleMessageSearch(query);
              },
              onClear: () {
                setState(() {
                  _searchQuery = '';
                  _searchController.clear();
                  _messageSearchResults = [];
                  _messageSearchLoading = false;
                });
                _messageSearchDebounce?.cancel();
              },
            ),
          ),
          const SizedBox(height: 8),
          if (_showSelfChatInSidebar) _buildSelfChatSidebarTile(),
          // Conversation list
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: _sidebarSearchItemCount,
              itemBuilder: (_, index) {
                if (_showMessageSearch) {
                  return _buildSearchSidebarItem(index);
                }
                if (index >= _filteredConversations.length) {
                  final footerIndex = index - _filteredConversations.length;
                  final showArchivedFooter = _archivedCount > 0;
                  if (showArchivedFooter && footerIndex == 0) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      child: PrysmListRow(
                        leading: Icon(
                          PrysmIcons.archive,
                          color: context.prysmStyle.tokens.accent,
                        ),
                        title: 'Archived',
                        subtitle: '$_archivedCount',
                        trailing: _archivedUnreadCount > 0
                            ? Container(
                                width: 8,
                                height: 8,
                                decoration: BoxDecoration(
                                  color: context.prysmStyle.tokens.accent,
                                  shape: BoxShape.circle,
                                ),
                              )
                            : null,
                        onTap: () => setState(() {
                          _viewingArchived = true;
                          _viewingBlocked = false;
                        }),
                      ),
                    );
                  }
                  return Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    child: PrysmListRow(
                      leading: Icon(
                        PrysmIcons.blockOutlined,
                        color: context.prysmStyle.tokens.accent,
                      ),
                      title: 'Blocked',
                      subtitle:
                          '$_blockedCount contact${_blockedCount == 1 ? '' : 's'}',
                      onTap: () => setState(() {
                        _viewingBlocked = true;
                        _viewingArchived = false;
                      }),
                    ),
                  );
                }

                final conv = _filteredConversations[index];
                return _buildConversationRow(conv);
              },
            ),
          ),
          // Bottom buttons
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              border: Border(
                top: BorderSide(
                  color: context.prysmStyle.tokens.divider.withValues(alpha: 0.1),
                  width: 1,
                ),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _tooltipIconButton(
                  icon: PrysmIcons.settingsOutlined,
                  tooltip: _desktopShortcutTooltip('Settings', 'I'),
                  onPressed: onShowSettings,
                ),
                _tooltipIconButton(
                  icon: PrysmIcons.personOutline,
                  tooltip: 'Profile',
                  onPressed: onShowProfile,
                ),
                _tooltipIconButton(
                  icon: PrysmIcons.groupAddOutlined,
                  tooltip: _desktopShortcutTooltip('Create Group', 'G'),
                  onPressed: _showCreateGroup,
                ),
                _tooltipIconButton(
                  icon: PrysmIcons.addCircle,
                  tooltip: _desktopShortcutTooltip('Add Contact', 'N'),
                  onPressed: _showAddUserDialog,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    widget.torConnectionController.clearReconnectCallbacks();
    _refreshTimer?.cancel();
    _loadUsersDebounce?.cancel();
    _messageSearchDebounce?.cancel();
    _batterySaverSub?.cancel();
    _inboundRefreshSub?.cancel();
    _groupMembershipSub?.cancel();
    widget.torConnectionController.stopMonitoring();
    widget.torConnectionController.removeListener(_onTorControllerChanged);
    _syncCoordinator?.dispose();
    if (NotificationService.onNotificationTap == _handleNotificationTap) {
      NotificationService.onNotificationTap = null;
    }
    if (NotificationService.onCallNotificationTap ==
        _handleCallNotificationAction) {
      NotificationService.onCallNotificationTap = null;
    }
    if (ShareIntentService.instance.onPendingShare == _handlePendingShareIntent) {
      ShareIntentService.instance.onPendingShare = null;
    }
    WidgetsBinding.instance.removeObserver(this);
    _searchController.dispose();
    // Deliberately no shutdown() here: the controller is owned by _MyAppState
    // and outlives this widget, so a rebuild that remounts HomeScreen would
    // kill a Tor process the new instance still needs. Real exit stops Tor via
    // quitApp() and the `detached` lifecycle branch below.
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Never stop Tor on `inactive` — that fires on focus loss, dialogs, and
    // notifications, which was causing random shutdowns during normal use.
    // Desktop exit is handled by MyWindowListener; mobile uses `detached`.
    if (state == AppLifecycleState.resumed) {
      _syncActiveConversationTracker();
      unawaited(_consumePendingCallAction());
    } else {
      ActiveConversationTracker.instance.clear();
    }
    unawaited(CallForegroundSession.instance.onAppLifecycleChanged(state));
    if (state == AppLifecycleState.detached) {
      widget.torConnectionController.shutdown();
    }
  }




  Future<void> _maybeBroadcastWakeHints({bool coldStart = false}) async {
    if (widget.torConnectionController.torStopped || widget.decoyMode) return;
    if (!coldStart) {
      final disconnectedAt = widget.torConnectionController.lastDisconnectedAt;
      if (disconnectedAt == null) return;
      final offlineFor = DateTime.now().difference(disconnectedAt);
      if (offlineFor < BatterySaverPolicy.wakeHintMinOfflineBeforeBroadcast) {
        return;
      }
    }
    await WakeHintService.instance.broadcastRecentPeerHints();
  }

  Future<void> _onTorReconnected() async {
    if (!widget.decoyMode && TransportProvider.isConfigured) {
      TransportProvider.instance.wsManager.prepareForTorReconnect();
    }
    final flushed = await _syncCoordinator?.onTorReconnected() ?? false;
    if (mounted) {
      scheduleLoadUsers(light: true);
      if (flushed) {
        _syncCoordinator?.notifyPendingActivity();
      }
      unawaited(_maybeBroadcastWakeHints());
    }
  }


  void _showTorStatusSheet() {
    showPrysmSheet<void>(
      context: context,
      builder: (ctx) {
        final style = ctx.prysmStyle;
        final tokens = style.tokens;
        return Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Tor connection', style: style.headlineStyle),
              const SizedBox(height: 12),
              Row(
                children: [
                  _torStatusDot(widget.torConnectionController.connectionState),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _torStatusLabel(widget.torConnectionController.connectionState),
                      style: style.bodyStyle,
                    ),
                  ),
                ],
              ),
              if (widget.torConnectionController.needsAttention) ...[
                const SizedBox(height: 8),
                Text(
                  'Tor needs attention — automatic recovery paused. '
                  'Try Restart Tor manually.',
                  style: style.bodyStyle.copyWith(color: tokens.danger),
                ),
              ],
              if (widget.torConnectionController.supervisor
                      ?.lastHealthFailureReason !=
                  null) ...[
                const SizedBox(height: 8),
                Text(
                  'Last issue: '
                  '${widget.torConnectionController.supervisor!.lastHealthFailureReason}',
                  style: style.captionStyle,
                ),
              ],
              if (widget.torConnectionController.supervisor != null &&
                  widget.torConnectionController.supervisor!.autoRestartCount >
                      0) ...[
                const SizedBox(height: 4),
                Text(
                  'Auto-restarts: '
                  '${widget.torConnectionController.supervisor!.autoRestartCount}',
                  style: style.captionStyle,
                ),
              ],
              if (TransportProvider.isConfigured) ...[
                const SizedBox(height: 8),
                Text(
                  'Outbound queue depth: '
                  '${TransportProvider.instance.outboundQueueDepth}',
                  style: style.captionStyle,
                ),
              ],
              if (!Platform.isAndroid && !Platform.isIOS) ...[
                const SizedBox(height: 4),
                Text(
                  'Health check: '
                  '${widget.torManager.lastHealthPollWasLight ? 'light (SOCKS)' : 'full (control)'}',
                  style: style.captionStyle,
                ),
              ],
              const SizedBox(height: 8),
              Text(
                'Onion: ${widget.onionAddress}',
                style: style.captionStyle,
              ),
              if (widget.torConnectionController.supervisor != null &&
                  widget
                      .torConnectionController.supervisor!.recentStderrLines
                      .isNotEmpty) ...[
                const SizedBox(height: 12),
                Text('Recent Tor log', style: style.titleStyle),
                const SizedBox(height: 4),
                Container(
                  width: double.infinity,
                  constraints: const BoxConstraints(maxHeight: 120),
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: tokens.surfaceElevated,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: SingleChildScrollView(
                    child: Text(
                      widget.torConnectionController.supervisor!
                          .recentStderrLines
                          .join('\n'),
                      style: style.captionStyle.copyWith(
                        fontFamily: 'monospace',
                        fontSize: 11,
                      ),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 20),
              if (widget.offlineMode) ...[
                PrysmButton(
                  label: widget.torConnecting ? 'Connecting…' : 'Connect Tor',
                  onPressed: widget.torConnecting
                      ? null
                      : () {
                          Navigator.pop(ctx);
                          widget.onConnectTor();
                        },
                ),
              ] else ...[
                PrysmButton(
                  label: 'Restart Tor',
                  onPressed:
                      widget.torConnectionController.connectionState ==
                              TorConnectionState.connecting ||
                          widget.torConnectionController.restartInProgress
                      ? null
                      : () {
                          Navigator.pop(ctx);
                          widget.torConnectionController.restart();
                        },
                ),
                const SizedBox(height: 8),
                PrysmButton(
                  label: 'New circuit',
                  variant: PrysmButtonVariant.secondary,
                  onPressed: widget.torConnectionController.restartInProgress
                      ? null
                      : () async {
                          Navigator.pop(ctx);
                          final ok = await widget.torManager.refreshCircuit();
                          if (!mounted) return;
                          showPrysmToast(
                            context,
                            ok
                                ? 'New Tor circuit requested'
                                : 'Circuit refresh failed',
                          );
                        },
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  String _onionPreview(String onion) {
    if (onion.isEmpty) return 'Connect Tor for Prysm ID';
    final short = onion.replaceAll('.onion', '');
    if (short.length <= 10) return short;
    return '${short.substring(0, 8)}…';
  }

  Widget _buildOfflineBanner() {
    if (!widget.offlineMode) return const SizedBox.shrink();
    final tokens = context.prysmStyle.tokens;
    return ColoredBox(
      color: tokens.danger.withValues(alpha: 0.15),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            Icon(
              PrysmIcons.wifiOff,
              size: 18,
              color: tokens.danger,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                widget.torConnecting
                    ? 'Connecting to Tor…'
                    : 'Offline — messages will send when Tor connects',
                style: TextStyle(
                  fontSize: 13,
                  color: tokens.danger,
                ),
              ),
            ),
            if (!widget.torConnecting)
              PrysmPressable(
                onTap: () => widget.onConnectTor(),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  child: Text(
                    'Connect',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: tokens.danger,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Color _torStatusColor(TorConnectionState state) => switch (state) {
    TorConnectionState.connected => const Color(0xFF4CAF50),
    TorConnectionState.connecting => const Color(0xFFFF9800),
    TorConnectionState.disconnected => const Color(0xFFF44336),
  };

  Widget _torStatusDot(TorConnectionState state, {double size = 10}) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: _torStatusColor(state),
        boxShadow: [
          BoxShadow(
            color: _torStatusColor(state).withValues(alpha: 0.45),
            blurRadius: 6,
            spreadRadius: 1,
          ),
        ],
      ),
    );
  }

  String _torStatusLabel(TorConnectionState state) {
    if (widget.torConnecting) return 'Connecting…';
    if (widget.offlineMode) return 'Offline';
    if (widget.torConnectionController.needsAttention) return 'Needs attention';
    return switch (state) {
      TorConnectionState.connected => 'Connected',
      TorConnectionState.connecting => 'Connecting…',
      TorConnectionState.disconnected => 'Disconnected',
    };
  }

  Widget _buildTorAppBarAction() {
    final color = _torStatusColor(widget.torConnectionController.connectionState);
    final narrow = MediaQuery.sizeOf(context).width < 400;
    final shortLabel = switch (widget.torConnectionController.connectionState) {
      TorConnectionState.connected => 'Tor',
      TorConnectionState.connecting => '…',
      TorConnectionState.disconnected => widget.offlineMode ? 'Off' : 'Off',
    };

    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: Semantics(
        label: 'Tor: ${_torStatusLabel(widget.torConnectionController.connectionState)}',
        button: true,
        child: PrysmPressable(
          onTap: _showTorStatusSheet,
          borderRadius: BorderRadius.circular(20),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: narrow ? 10 : 12,
                vertical: 8,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(PrysmIcons.shieldOutlined, size: 18, color: color),
                  const SizedBox(width: 6),
                  _torStatusDot(widget.torConnectionController.connectionState, size: 8),
                  if (!narrow) ...[
                    const SizedBox(width: 6),
                    Text(
                      shortLabel,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: color,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _copyPrysmId() {
    final id = encodeOnionToBase58(appUser.id);
    Clipboard.setData(ClipboardData(text: id));
    showPrysmToast(context, 'Prysm ID copied to clipboard');
  }

  Widget _buildEmptyHomeState() {
    final prysmId = encodeOnionToBase58(appUser.id);
    final contactCount = contacts
        .where((c) => c.id != widget.onionAddress)
        .length;
    final groupCount = groups.length;
    final displayName = appUser.name.isNotEmpty ? appUser.name : 'there';

    return EmptyHomeState(
      displayName: displayName,
      prysmId: prysmId,
      contactCount: contactCount,
      groupCount: groupCount,
      onCopyId: _copyPrysmId,
      onShowQr: () => showPrysmIdQrDialog(context, prysmId),
      onAddContact: _showAddUserDialog,
      onCreateGroup: _showCreateGroup,
      onScanQr: QrPlatform.isScanSupported
          ? () async {
              final scanned = await Navigator.push<String>(
                context,
                PrysmPageRoute(page: const QrScannerScreen()),
              );
              if (scanned != null && scanned.isNotEmpty) {
                _showAddUserDialog(prefilledId: scanned);
              }
            }
          : null,
    );
  }


  void clearChat() {
    setState(() {
      loadUsers();
      selectedContact = null;
      selectedConversation = null;
      showSelfChat = false;
    });
    _syncActiveConversationTracker();
  }

  Widget _buildChatBody() {
    if (showProfile) {
      return ProfileScreen(
        user: appUser,
        onClose: () => setState(() => showProfile = false),
        onUpdate: onUpdateProfile,
        reloadUsers: () => loadUsers(),
        onScanResult: (scanned) => _showAddUserDialog(prefilledId: scanned),
      );
    }
    if (showSettings) {
      return SettingsScreen(
        onClose: () => setState(() => showSettings = false),
        onThemeChanged: onThemeChanged,
        onAppearanceChanged: onAppearanceChanged,
        torManager: widget.torManager,
        keyManager: widget.decoyMode ? null : widget.keyManager,
        onionAddress: widget.decoyMode ? null : widget.onionAddress,
        offlineMode: widget.offlineMode,
        torConnecting: widget.torConnecting,
        onConnectTor: widget.onConnectTor,
        decoyMode: widget.decoyMode,
      );
    }
    if (showSelfChat && !widget.decoyMode) {
      final scrollId = _pendingScrollToMessageId;
      _pendingScrollToMessageId = null;
      return SelfChatScreen(
        key: const ValueKey('self_chat'),
        userId: appUser.id,
        userName: appUser.name,
        avatarBase64: appUser.avatarBase64,
        keyManager: widget.keyManager,
        onCloseChat: () => clearChat(),
        reloadSidebar: () => loadUsers(),
        initialScrollToMessageId: scrollId,
      );
    }
    if (selectedConversation is GroupConversation) {
      final group = (selectedConversation as GroupConversation).group;
      if (widget.decoyMode) {
        return DecoyChatScreen(
          key: ValueKey('decoy_group_${group.id}'),
          conversationId: group.id,
          title: group.name,
          avatarName: group.name,
          avatarBase64: group.avatarBase64,
          isGroup: true,
          initialMessages: _decoyMessages[group.id] ?? const [],
          onCloseChat: () => clearChat(),
          torStatusAction: _buildTorAppBarAction(),
        );
      }
      final scrollId = _pendingScrollToMessageId;
      _pendingScrollToMessageId = null;
      return GroupChatScreen(
        key: ValueKey('group_${group.id}'),
        userId: appUser.id,
        group: group,
        contacts: contacts,
        keyManager: widget.keyManager,
        reloadConversations: () => loadUsers(),
        onCloseChat: () => clearChat(),
        torStatusAction: widget.decoyMode ? null : _buildTorAppBarAction(),
        initialScrollToMessageId: scrollId,
      );
    }
    if (selectedContact != null) {
      if (widget.decoyMode) {
        final contact = selectedContact!;
        return DecoyChatScreen(
          key: ValueKey('decoy_dm_${contact.id}'),
          conversationId: contact.id,
          title: contact.displayName,
          avatarName: contact.displayName,
          avatarBase64: contact.avatarBase64,
          initialMessages: _decoyMessages[contact.id] ?? const [],
          onCloseChat: () => clearChat(),
          torStatusAction: _buildTorAppBarAction(),
        );
      }
      final scrollId = _pendingScrollToMessageId;
      _pendingScrollToMessageId = null;
      return ChatScreen(
        key: ValueKey('dm_${selectedContact!.id}'),
        userId: appUser.id,
        userName: appUser.name,
        peerId: selectedContact!.id,
        peerName: selectedContact!.displayName,
        peerAvatarBase64: selectedContact!.avatarBase64,
        peerPublicKeyPem: selectedContact!.publicKeyPem,
        torManager: widget.torManager,
        keyManager: widget.keyManager,
        currentTheme: currentTheme,
        clearChat: () => clearChat(),
        reloadUsers: () => loadUsers(),
        onCloseChat: () => clearChat(),
        torStatusAction: widget.decoyMode ? null : _buildTorAppBarAction(),
        initialScrollToMessageId: scrollId,
      );
    }
    return _buildEmptyHomeState();
  }

  Widget _buildHomeHeader({
    required bool showMenuButton,
    required List<Widget> actions,
  }) {
    final tokens = context.prysmStyle.tokens;
    return ColoredBox(
      color: tokens.surface,
      child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: 70,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  children: [
                    if (showMenuButton)
                      _tooltipIconButton(
                        icon: PrysmIcons.menu,
                        tooltip: 'Open menu',
                        onPressed: () => setState(() => _sidebarOpen = true),
                      ),
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: tokens.accent.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Image.asset(
                        'assets/logo.png',
                        height: 40,
                        width: 40,
                        fit: BoxFit.contain,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        '${settings.name} Chat',
                        style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    ...actions,
                  ],
                ),
              ),
            ),
            Container(height: 1, color: tokens.divider),
          ],
        ),
    );
  }

  Widget _buildHomeBody({required bool isMobile}) {
    final tokens = context.prysmStyle.tokens;
    final showHomeHeader = isMobile &&
        selectedConversation == null &&
        !showProfile &&
        !showSettings &&
        !showSelfChat;

    final content = ColoredBox(
      color: tokens.background,
      child: Column(
        children: [
          if (isMobile)
            SizedBox(height: MediaQuery.paddingOf(context).top),
          if (showHomeHeader)
            _buildHomeHeader(
              showMenuButton: true,
              actions: [
                _buildTorAppBarAction(),
                _tooltipIconButton(
                  icon: PrysmIcons.settingsOutlined,
                  tooltip: 'Settings',
                  onPressed: () => setState(() {
                    showSettings = true;
                    showSelfChat = false;
                  }),
                ),
              ],
            )
          else if (!isMobile)
            _buildHomeHeader(
              showMenuButton: false,
              actions: [
                _buildTorAppBarAction(),
                _tooltipIconButton(
                  icon: PrysmIcons.settingsOutlined,
                  tooltip: _desktopShortcutTooltip('Settings', 'I'),
                  onPressed: onShowSettings,
                ),
              ],
            ),
          _buildOfflineBanner(),
          Expanded(
            child: isMobile
                ? MediaQuery.removePadding(
                    context: context,
                    removeTop: true,
                    child: _buildChatBody(),
                  )
                : Row(
                    children: [
                      buildSidebar(),
                      Expanded(child: _buildChatBody()),
                    ],
                  ),
          ),
        ],
      ),
    );

    if (!isMobile || !_sidebarOpen) {
      return content;
    }

    return Stack(
      children: [
        content,
        Positioned.fill(
          child: GestureDetector(
            onTap: () => setState(() => _sidebarOpen = false),
            child: const ColoredBox(color: Color(0x66000000)),
          ),
        ),
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          child: buildSidebar(),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final isMobile = MediaQuery.of(context).size.width < 600;

    if (isLoading) {
      return const PrysmPage(body: Center(child: PrysmProgressIndicator()));
    }

    if (isMobile) {
      return _buildHomeBody(isMobile: true);
    }

    return CallbackShortcuts(
      bindings: {
        ..._desktopShortcut(LogicalKeyboardKey.keyN, _showAddUserDialog),
        ..._desktopShortcut(LogicalKeyboardKey.keyI, onShowSettings),
        ..._desktopShortcut(LogicalKeyboardKey.keyG, _showCreateGroup),
      },
      child: Focus(
        autofocus: true,
        child: _buildHomeBody(isMobile: false),
      ),
    );
  }
}
