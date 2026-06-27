import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:encrypt/encrypt.dart' as e;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_chat_ui/flutter_chat_ui.dart';
import 'package:flutter_chat_core/flutter_chat_core.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:prysm/transport/transport_preference.dart';
import 'package:prysm/transport/transport_provider.dart';
import 'package:prysm/util/tor_runtime_gate.dart';
import 'package:prysm/database/message_reactions.dart';
import 'package:prysm/database/messages.dart';
import 'package:prysm/screens/chat_profile_screen.dart';
import 'package:prysm/screens/widgets/prysm_chat_composer_overlay.dart';
import 'package:prysm/util/chat_scroll.dart';
import 'package:prysm/util/scroll_to_chat_message.dart';
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
import 'package:prysm/services/peer_presence_tracker.dart';
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
import 'package:prysm/services/battery_saver_service.dart';
import 'package:prysm/services/chat_service.dart'; // ✅ ADD THIS
import 'package:prysm/services/conversation_preferences_service.dart';
import 'package:prysm/util/battery_saver_policy.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/util/file_encrypt.dart';
import 'package:prysm/util/tor_service.dart';
import 'package:prysm/util/group_crypto.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:prysm/models/contact.dart';

import 'package:uuid/uuid.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';

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
  late final User _user;
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
  Timer? _pingTimer;
  Timer? _presenceStaleTimer;
  StreamSubscription<void>? _batterySaverSub;

  Set<String> selectedMessageIds = {};
  Message? _replyToMessage;
  final Map<String, double> _dragOffsets = {};

  Key _chatKey = UniqueKey();
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
  StreamSubscription? _readReceiptRefreshSub;
  Timer? _readReceiptDebounce;
  late MessageModifyService _modifyService;
  String? _highlightedMessageId;
  Timer? _highlightTimer;

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

  @override
  void initState() {
    super.initState();
    _currentTheme = widget.currentTheme;
    _peerName = widget.peerName;
    _peerAvatarBase64 = widget.peerAvatarBase64;
    _user = User(id: widget.userId);

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

    _presenceTracker = PeerPresenceTracker();
    _listScrollController.addListener(_onListScroll);
    _initializeChat(); // ✅ NEW METHOD
    _checkPeerStatus(preference: TransportPreference.wsIfConnected);
    _startPeerPingTimer();
    _startPresenceStaleTimer();
    _batterySaverSub = BatterySaverService.instance.onChanged.listen((_) {
      if (mounted) {
        _startPeerPingTimer();
        _startPresenceStaleTimer();
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
      (_) => _syncPeerPresence(),
    );
  }

  void _startPeerPingTimer() {
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(
      BatterySaverPolicy.peerStatusInterval(),
      (_) => _checkPeerStatus(preference: TransportPreference.wsIfConnected),
    );
  }

  // ✅ NEW: Initialize ChatService
  Future<void> _initializeChat() async {
    final success = await _chatService.initialize(widget.peerPublicKeyPem);

    if (!success && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not connect to peer. Messages will be queued.'),
          duration: Duration(seconds: 2),
        ),
      );
    }

    // ✅ Listen to ChatService streams
    _newMessagesSub = _chatService.onNewMessages.listen(_handleNewMessages);
    _statusSub = _chatService.onMessageStatus.listen(_handleStatusUpdate);
    _reachableSub = _chatService.onPeerReachable.listen((_) {
      if (mounted) _recordPeerActivity();
    });
    _reactionSub = _reactionService.onReactionsChanged.listen(_applyReactionUpdate);
    _reactionRefreshSub =
        ReactionRefreshNotifier.instance.onReactionChanged.listen(_applyReactionUpdate);
    _modifyRefreshSub = MessageModifyRefreshNotifier.instance.onModifyChanged
        .listen(_applyModifyUpdate);
    _readReceiptRefreshSub =
        ReadReceiptRefreshNotifier.instance.onReadReceiptChanged
            .listen(_applyReadReceiptUpdate);

    await _loadInitialMessages();
    await _markInboundAsRead();

    if (mounted && _messages.messages.isNotEmpty) {
      _stickToBottom = true;
      scheduleScrollChatToBottom(_messages, isMounted: () => mounted);
    }

    // ✅ Start ChatService background tasks
    _chatService.startPolling();
    _chatService.startSendQueue();
    if (TransportProvider.isConfigured) {
      TransportProvider.instance.pinPeer(widget.peerId);
    }
  }

  void _suspendPresenceProbeDuringMediaUpload() {
    _presenceTracker.suspendProbeFailuresFor(
      BatterySaverPolicy.mediaUploadPresenceGrace,
    );
  }

  // ✅ NEW: Handle incoming messages from ChatService
  void _handleNewMessages(List<Map<String, dynamic>> rawMessages) async {
    if (!mounted) return;

    if (rawMessages.any((msg) => msg['senderId'] == widget.peerId)) {
      _recordPeerActivity();
    }

    try {
      final decrypted = await decryptMessagesDeferred(
        rawMessages,
        widget.keyManager,
      );

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

    _readReceiptDebounce?.cancel();
    _readReceiptDebounce = Timer(const Duration(milliseconds: 100), () async {
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

  @override
  void dispose() {
    // ✅ DISPOSE ChatService
    _chatService.dispose();
    _reactionService.dispose();
    _newMessagesSub?.cancel();
    _statusSub?.cancel();
    _reachableSub?.cancel();
    _reactionSub?.cancel();
    _reactionRefreshSub?.cancel();
    _modifyRefreshSub?.cancel();
    _readReceiptRefreshSub?.cancel();
    _readReceiptDebounce?.cancel();
    _highlightTimer?.cancel();
    _pingTimer?.cancel();
    _presenceStaleTimer?.cancel();
    _batterySaverSub?.cancel();

    _debounceTimer?.cancel();
    _listScrollController.removeListener(_onListScroll);
    _listScrollController.dispose();
    if (TransportProvider.isConfigured) {
      TransportProvider.instance.unpinPeer(widget.peerId);
    }
    super.dispose();
  }

  /// Check peer status by calling /profile — determines online/offline
  /// AND fetches fresh name/avatar in one round-trip.
  Future<void> _checkPeerStatus({
    TransportPreference preference = TransportPreference.wsPreferred,
  }) async {
    if (TorRuntimeGate.blocked) return;
    try {
      final body = await TransportProvider.getProfileOrFallback(
        widget.peerId,
        preference: preference,
      );
      final data = jsonDecode(body) as Map<String, dynamic>;

      if (!mounted) return;

      _recordPeerActivity();

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

      if (mounted) _syncPeerPresence();
    } catch (e) {
      debugPrint('Profile check failed: $e');
      if (!mounted) return;
      final errStr = e.toString();
      final isHardFailure = errStr.contains('hostUnreachable') ||
          errStr.contains('connectionRefused') ||
          errStr.contains('ttlExpired') ||
          e is TimeoutException;
      _presenceTracker.considerProfileFailure(isHardFailure: isHardFailure);
      _syncPeerPresence();
    }
  }

  void resetChatState() {
    _messages = InMemoryChatController();
    _replyToMessage = null;
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
      // ✅ REINITIALIZE ChatService on peer change
      _chatService.dispose();
      _newMessagesSub?.cancel();
      _statusSub?.cancel();
      _reachableSub?.cancel();
      _pingTimer?.cancel();
      _presenceStaleTimer?.cancel();

      _presenceTracker = PeerPresenceTracker();
      setState(() {
        resetChatState();
        _chatKey = UniqueKey();
        _peerName = widget.peerName;
        _peerAvatarBase64 = widget.peerAvatarBase64;
        _peerOnline = null;
      });

      _chatService = ChatService(
        userId: widget.userId,
        peerId: widget.peerId,
        keyManager: widget.keyManager,
      );
      _reactionService.dispose();
      _modifyRefreshSub?.cancel();
      _reactionService = ReactionService.direct(
        userId: widget.userId,
        keyManager: widget.keyManager,
        peerId: widget.peerId,
      );
      _modifyService = MessageModifyService.direct(
        userId: widget.userId,
        keyManager: widget.keyManager,
        peerId: widget.peerId,
      );

      _initializeChat();
      _checkPeerStatus();
      _startPeerPingTimer();
      _startPresenceStaleTimer();
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

  String _decryptDirectTextMessage(Map<String, dynamic> msg, KeyManager keyManager) {
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

    return keyManager.decryptMessage(wire);
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
              authorId: User(id: msg['senderId']).id,
              createdAt: DateTime.fromMillisecondsSinceEpoch(msg['timestamp']),
              id: msg['id'],
              replyToMessageId: msg['replyTo'],
              text: _decryptDirectTextMessage(msg, keyManager),
              metadata: meta.isEmpty ? null : meta,
            ),
          );
        } else if (msg['type'] == 'file') {
          final fileName = msg['fileName'] ?? 'Unknown';
          final msgId = msg['id'] as String;
          messages.add(
            FileMessage(
              id: msgId,
              authorId: User(id: msg['senderId']).id,
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
              authorId: User(id: msg['senderId']).id,
              createdAt: DateTime.fromMillisecondsSinceEpoch(msg['timestamp']),
              replyToMessageId: msg['replyTo'],
              name: msg['fileName'] ?? 'voice_message.wav',
              size: msg['fileSize'] ?? 0,
              source: msg['message'],
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
                authorId: User(id: msg['senderId']).id,
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
                authorId: User(id: msg['senderId']).id,
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
            authorId: User(id: msg['senderId']).id,
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
      final updated = message.copyWith(
        text: newText,
        metadata: {...?message.metadata, 'edited': true},
      );
      setState(() {
        _messages.updateMessage(message, updated);
        _messageCache[message.id] = updated;
      });
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not edit message')),
      );
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
              Theme.of(context).colorScheme.onSurface.withAlpha(180),
            )
          : null,
    );
  }

  String _replyPreviewText(Message message) {
    if (isMessageDeleted(message)) return 'Deleted';
    if (message is TextMessage) return message.text;
    if (message is ImageMessage) return '📷 Image';
    if (message is FileMessage) return '📎 File: ${message.name}';
    return 'Message';
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

    final newMessages = await decryptMessagesDeferred(
      modifiableList,
      widget.keyManager,
    );

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

    var replyToId = _replyToMessage?.id;

    // ✅ Generate ID and show UI IMMEDIATELY
    final messageId = const Uuid().v4();

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

    // ✅ NOW send in background (non-blocking)
    _chatService
        .sendTextMessage(text, replyToId: replyToId, messageId: messageId)
        .then((sentId) {
          if (sentId == null && mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  'Message queued. Will send when peer is available.',
                ),
              ),
            );
          }
        });
  }

  Future<void> _sendFile(Uint8List bytes, String fileName, String type, {bool viewOnce = false}) async {
    if (!mounted) return;

    var replyToId = _replyToMessage?.id;

    // ✅ Generate ID and show UI IMMEDIATELY
    final messageId = const Uuid().v4();

    setState(() {
      if (type == "file") {
        _messages.insertMessage(
          messageWithPendingStatus(
            FileMessage(
              authorId: _user.id,
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
              authorId: _user.id,
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
    });
    _scheduleScrollToBottomAfterSend();

    // ✅ NOW send in background
    _suspendPresenceProbeDuringMediaUpload();
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
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('File queued. Will send when peer is available.'),
              ),
            );
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

    Uint8List bytes = await pickedFile.readAsBytes();

    if (bytes.length > 500 * 1024) {
      try {
        final compressed = await FlutterImageCompress.compressWithList(
          bytes,
          minHeight: 1080,
          minWidth: 1080,
          quality: 70,
        );
        bytes = compressed;
      } catch (e) {
        print("Compression failed: $e");
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Image compression failed, sending original.')),
          );
        }
      }
    }

    if (!mounted) return;

    final viewOnce = await ImageSendPreviewScreen.open(context, bytes);
    if (viewOnce == null || !mounted) return;

    _sendFile(bytes, pickedFile.name, "image", viewOnce: viewOnce);
  }

  Future<void> _handleSendFile() async {
    final result = await FilePicker.platform.pickFiles(withData: true);
    if (result == null || result.files.isEmpty) return;

    final file = result.files.first;
    _sendFile(file.bytes!, file.name, "file");
  }

  void _handleSend(dynamic message) {
    if (message is TextMessage && message.text.isNotEmpty) {
      _handleSendText(message.text);
    } else if (message is String && message.isNotEmpty) {
      _handleSendText(message);
    }
  }

  Future<void> _handleSendVoice(Uint8List bytes, int durationMs) async {
    if (!mounted) return;

    final messageId = const Uuid().v4();

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
            authorId: _user.id,
            createdAt: DateTime.now(),
            id: messageId,
            name: 'voice_message.wav',
            size: bytes.length,
            source: 'audio:$durationMs:$cachePath',
            metadata: {'waveform': waveformMeta},
          ),
        ),
        index: _messages.messages.length,
      );
    });
    _scheduleScrollToBottomAfterSend();

    _suspendPresenceProbeDuringMediaUpload();
    _chatService
        .sendFileMessage(bytes, 'voice_message.wav', 'audio', messageId: messageId)
        .then((sentId) {
          if (sentId == null && mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Voice message queued. Will send when peer is available.')),
            );
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Message not found in loaded history')),
      );
    }
  }

  void _openChatProfile() async {
    final peerContact = Contact(
      id: widget.peerId,
      name: _peerName,
      avatarUrl: '',
      avatarBase64: _peerAvatarBase64,
      publicKeyPem: widget.peerPublicKeyPem ?? '',
    );

    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ChatProfileScreen(
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
              _chatKey = UniqueKey();
            });
            _loadInitialMessages();
          },
          onDeleteContact: () async {
            await ConversationPreferencesService.instance.delete(widget.peerId);
            await DBHelper.deleteUser(widget.peerId);
            resetChatState();
            setState(() {
              _messages = InMemoryChatController();
              _chatKey = UniqueKey();
              _replyToMessage = null;
            });
            widget.clearChat();
          },
          onPreferencesChanged: widget.reloadUsers,
          onArchived: () {
            Navigator.of(context).pop();
            widget.clearChat();
          },
        ),
      ),
    );

    if (result is Contact) {
      setState(() => _peerName = result.displayName);
    } else if (result is String) {
      await _scrollToMessage(result);
    }
  }

  Widget _buildReplyPreview() {
    if (_replyToMessage == null) return SizedBox.shrink();
    final previewText = _replyPreviewText(_replyToMessage!);
    return Container(
      color: Theme.of(context).brightness == Brightness.dark
          ? Theme.of(context).colorScheme.secondary
          : Theme.of(context).colorScheme.primary,
      padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
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
            icon: Icon(Icons.close),
            color: Theme.of(context).brightness == Brightness.dark
                ? Colors.black
                : Colors.white,
            onPressed: () => setState(() => _replyToMessage = null),
          ),
        ],
      ),
    );
  }

  String _getMessageText(Message message) {
    if (message is TextMessage) return message.text;
    if (message is FileMessage) return message.name;
    if (message is ImageMessage) return '📷 Image';
    return '';
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
    final tiles = <Widget>[
      if (text.isNotEmpty)
        ListTile(
          leading: const Icon(Icons.copy),
          title: const Text('Copy'),
          onTap: () {
            Navigator.pop(context);
            Clipboard.setData(ClipboardData(text: text));
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Copied to clipboard'),
                duration: Duration(seconds: 1),
              ),
            );
          },
        ),
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
        leading: Icon(Icons.delete_outline, color: Colors.red[400]),
        title: Text(
          isSentByMe ? 'Delete for everyone' : 'Delete',
          style: TextStyle(color: Colors.red[400]),
        ),
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

  Future<void> _deleteMessage(Message message) async {
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
        title: GestureDetector(
          onTap: () {
            showModalBottomSheet(
              context: context,
              builder: (BuildContext context) {
                return Container(
                  height: 200,
                  decoration: BoxDecoration(
                    color: Theme.of(context).scaffoldBackgroundColor,
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(20),
                    ),
                  ),
                  child: Column(
                    children: [
                      Container(
                        margin: const EdgeInsets.all(16),
                        height: 4,
                        width: 40,
                        decoration: BoxDecoration(
                          color: Theme.of(context).dividerColor,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      ListTile(
                        leading: ContactAvatar(
                          name: _peerName,
                          radius: 20,
                          avatarBase64: _peerAvatarBase64,
                        ),
                        title: Text(
                          _peerName,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        subtitle: const Text('View profile'),
                        onTap: () {
                          Navigator.pop(context);
                          _openChatProfile();
                        },
                      ),
                    ],
                  ),
                );
              },
            );
          },
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
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _peerName,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  if (_peerOnline == null)
                    Text(
                      'Checking...',
                      style: TextStyle(
                        color: Theme.of(context).hintColor,
                        fontSize: 12,
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
                                ? Colors.green
                                : Theme.of(context).colorScheme.onSurface.withAlpha(100),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          _peerOnline! ? 'Online' : 'Offline',
                          style: TextStyle(
                            color: _peerOnline!
                                ? Colors.green
                                : Theme.of(context).hintColor,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ],
          ),
        ),
        actions: selectedMessageIds.isNotEmpty
            ? [
                IconButton(
                  icon: Icon(Icons.delete),
                  onPressed: deleteSelectedMessages,
                ),
                IconButton(
                  icon: const Icon(Icons.more_vert),
                  onPressed: _openChatProfile,
                ),
              ]
            : [
                IconButton(
                  icon: const Icon(Icons.more_vert),
                  onPressed: _openChatProfile,
                ),
              ],
        elevation: 2,
        shadowColor: Colors.black.withValues(alpha: 0.1),
      ),
      body: SafeArea(
        child: Chat(
          key: _chatKey,
                chatController: _messages,
                currentUserId: widget.userId,
                theme: ChatTheme.fromThemeData(Theme.of(context)),
                resolveUser: (_) async => _user,
                onMessageSend: (message) {
                  _handleSend(message);
                },
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
                  chatMessageBuilder:
                      (
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
                        if (index > 0 &&
                            index - 1 < _messages.messages.length) {
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

                        bool showDateHeader =
                            index == 0 ||
                            prevDay == null ||
                            !currentDay.isAtSameMomentAs(prevDay);

                        Widget replyPreviewWidget = const SizedBox.shrink();
                        final replyId = message.replyToMessageId;
                        if (replyId != null) {
                          Message? repliedMessage;
                          try {
                            repliedMessage = _messages.messages.firstWhere(
                              (m) => m.id == replyId,
                            );
                          } catch (_) {
                            repliedMessage = null;
                          }

                          if (repliedMessage != null) {
                            final previewText = _replyPreviewText(repliedMessage);

                            replyPreviewWidget = Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              constraints: BoxConstraints(
                                maxWidth:
                                    MediaQuery.of(context).size.width * 0.7,
                              ),
                              child: Text(
                                previewText,
                                style: TextStyle(
                                  fontStyle: FontStyle.italic,
                                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                textAlign: isSentByMe
                                    ? TextAlign.right
                                    : TextAlign.left,
                              ),
                            );
                          }
                        }

                        bool isSelected = selectedMessageIds.contains(
                          message.id,
                        );

                        return Column(
                          children: [
                            if (showDateHeader)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 8,
                                ),
                                alignment: Alignment.center,
                                child: Text(
                                  "${msgDate.day}/${msgDate.month}/${msgDate.year}",
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: Colors.grey,
                                  ),
                                ),
                              ),
                            GestureDetector(
                              behavior: HitTestBehavior.translucent,
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
                              onLongPressStart: (details) {
                                if (selectedMessageIds.isNotEmpty) {
                                  // Multi-select mode: toggle selection
                                  setState(() {
                                    if (isSelected) {
                                      selectedMessageIds.remove(message.id);
                                    } else {
                                      selectedMessageIds.add(message.id);
                                    }
                                  });
                                } else {
                                  // Single message: show context menu
                                  _showMessageMenu(context, message, details.globalPosition);
                                }
                              },
                              child: Transform.translate(
                                offset: Offset(
                                  isSentByMe
                                      ? -(_dragOffsets[message.id] ?? 0)
                                      : (_dragOffsets[message.id] ?? 0),
                                  0,
                                ),
                                child: Container(
                                  decoration: BoxDecoration(
                                    color:
                                        selectedMessageIds.contains(message.id)
                                        ? Theme.of(context).colorScheme.primary.withAlpha(40)
                                        : _highlightedMessageId == message.id
                                            ? Theme.of(context).colorScheme.tertiary.withAlpha(60)
                                        : Colors.transparent,
                                  ),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 4,
                                    ),
                                    child: SizeTransition(
                                      sizeFactor: animation,
                                      child: Row(
                                        mainAxisAlignment: isSentByMe
                                            ? MainAxisAlignment.end
                                            : MainAxisAlignment.start,
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Flexible(
                                            child: Column(
                                              crossAxisAlignment: isSentByMe
                                                  ? CrossAxisAlignment.end
                                                  : CrossAxisAlignment.start,
                                              children: [
                                                replyPreviewWidget,
                                                _displayChildForMessage(
                                                  message,
                                                  child,
                                                  isSentByMe,
                                                ),
                                                if (!isMessageDeleted(message))
                                                  _reactionBarFor(
                                                    message,
                                                    isSentByMe,
                                                  ),
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
                  fileMessageBuilder: fileMessageBuilder,
                  imageMessageBuilder: myImageMessageBuilder,
                  textMessageBuilder: textMessageBuilder,

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

  // ==================== MESSAGE BUILDERS (KEEP AS-IS) ====================

  Widget myImageMessageBuilder(
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
        "${msgDate.hour.toString().padLeft(2, '0')}:${msgDate.minute.toString().padLeft(2, '0')}";

    // ✅ Determine tick status
    Widget tickWidget = const SizedBox.shrink();
    if (isSentByMe) {
      tickWidget = _buildStatusWidget(message, isSentByMe, Colors.white.withAlpha(220));
    }

    // View-once: already viewed → show "Opened" placeholder
    if (isViewOnce && isViewed) {
      return Column(
        crossAxisAlignment: isSentByMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
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

    // View-once: not yet viewed → show blurred placeholder with eye icon
    if (isViewOnce && !isViewed) {
      return Column(
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
                  MaterialPageRoute(
                    builder: (_) => _ViewOnceScreen(imageBytes: decryptedBytes),
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
                  const SizedBox(height: 4),
                  Text(
                    '🔒 Disappears after viewing',
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.grey[500],
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
              Icon(Icons.timer, size: 12, color: Colors.grey[500]),
              const SizedBox(width: 2),
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
      decryptFromDb: () => _decryptImageFromDb(message.id),
    );
  }

  Widget fileMessageBuilder(
    BuildContext context,
    FileMessage message,
    int index, {
    required bool isSentByMe,
    MessageGroupStatus? groupStatus,
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
      final tickColor = Theme.of(context).colorScheme.onPrimary;
      tickWidget =
          _buildStatusWidget(message, isSentByMe, tickColor.withAlpha(220));
    }

    return FileAttachmentBubble(
      fileName: message.name,
      fileSize: message.size,
      timeString: timeString,
      isSentByMe: isSentByMe,
      tickWidget: tickWidget,
      resolveBytes: () => FileAttachmentResolver.resolve(
        message,
        keyManager: widget.keyManager,
      ),
    );
  }

  Widget textMessageBuilder(
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
        "${msgDate.hour.toString().padLeft(2, '0')}:${msgDate.minute.toString().padLeft(2, '0')}";

    // ✅ Determine tick status
    Widget tickWidget = const SizedBox.shrink();
    if (isSentByMe) {
      final tickColor = isSentByMe
          ? Theme.of(context).colorScheme.onPrimary.withAlpha(200)
          : Theme.of(context).colorScheme.onSecondary.withAlpha(200);
      tickWidget = _buildStatusWidget(message, isSentByMe, tickColor);
    }

    return IntrinsicWidth(
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
            LinkedMessageText(
              text: message.text,
              textColor: isSentByMe
                  ? Theme.of(context).colorScheme.onPrimary
                  : Theme.of(context).colorScheme.onSecondary,
              fontSize: 14,
              onOpenUrl: _openUrl,
            ),
            const SizedBox(height: 4),
            // ✅ Time and ticks aligned to the right
            Align(
              alignment: Alignment.centerRight,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (message.metadata?['edited'] == true) ...[
                    Text(
                      'edited',
                      style: TextStyle(
                        fontSize: 10,
                        fontStyle: FontStyle.italic,
                        color: isSentByMe
                            ? Theme.of(context).colorScheme.onPrimary.withAlpha(160)
                            : Theme.of(context)
                                .colorScheme
                                .onSecondary
                                .withAlpha(160),
                      ),
                    ),
                    const SizedBox(width: 4),
                  ],
                  Text(
                    timeString,
                    style: TextStyle(
                      fontSize: 10,
                      color: isSentByMe
                          ? Theme.of(context).colorScheme.onPrimary.withAlpha(180)
                          : Theme.of(context).colorScheme.onSecondary.withAlpha(180),
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
        ? Theme.of(context).colorScheme.onPrimary
        : Theme.of(context).colorScheme.onSecondary;
    Widget tickWidget = _buildStatusWidget(message, isSentByMe, tickColor.withAlpha(220));

    return VoiceMessageBubble(
      message: message,
      isSentByMe: isSentByMe,
      timeString: timeString,
      tickWidget: tickWidget,
      decryptAudio: message.source.startsWith('audio:')
          ? null
          : (encryptedSource) async {
              final hybrid = jsonDecode(encryptedSource);
              final rsaEncryptedAesKey = hybrid['aes_key'];
              final iv = e.IV.fromBase64(hybrid['iv']);
              final encryptedData = base64Decode(hybrid['data']);
              final aesKeyBytes =
                  widget.keyManager.decryptMyMessageBytes(rsaEncryptedAesKey);
              final aesKey = e.Key(Uint8List.fromList(aesKeyBytes));
              return AESHelper.decryptBytes(encryptedData, aesKey, iv);
            },
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
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.timer, size: 16, color: Colors.white70),
            const SizedBox(width: 6),
            const Text(
              'View Once',
              style: TextStyle(fontSize: 16, color: Colors.white70),
            ),
          ],
        ),
        centerTitle: true,
      ),
      body: Center(
        child: InteractiveViewer(
          child: Image.memory(widget.imageBytes),
        ),
      ),
    );
  }
}

