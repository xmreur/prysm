import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:audioplayers/audioplayers.dart';
import 'package:encrypt/encrypt.dart' as e;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_chat_ui/flutter_chat_ui.dart';
import 'package:flutter_chat_core/flutter_chat_core.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:prysm/client/TorHttpClient.dart';
import 'package:prysm/database/messages.dart';
import 'package:prysm/screens/chat_profile_screen.dart';
import 'package:prysm/screens/message_composer.dart';
import 'package:prysm/screens/widgets/contact_avatar.dart';
import 'package:prysm/services/chat_service.dart'; // ✅ ADD THIS
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/util/file_encrypt.dart';
import 'package:prysm/util/tor_service.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:scroll_to_index/scroll_to_index.dart';
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

  var _messages = InMemoryChatController();
  final Map<String, TextMessage> _messageCache = {};
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
  int _failedPings = 0;
  bool _probeConfirmedOffline = false; // Set by _checkPeerStatus on hard failure
  Timer? _pingTimer;

  Set<String> selectedMessageIds = {};
  Message? _replyToMessage;
  Map<String, double> _dragOffsets = {};

  Key _chatKey = UniqueKey();
  final AutoScrollController _scrollController = AutoScrollController();
  Timer? _debounceTimer;

  // ✅ ADD ChatService subscriptions
  StreamSubscription? _newMessagesSub;
  StreamSubscription? _statusSub;
  StreamSubscription? _reachableSub;

  void _scrollListener() {
    if (_scrollController.position.pixels <= 50 && !_loading && _hasMore) {
      if (_debounceTimer?.isActive ?? false) return;
      _debounceTimer = Timer(const Duration(milliseconds: 600), () async {
        await _loadMoreMessages();
      });
    }
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

    _scrollController.addListener(_scrollListener);
    _initializeChat(); // ✅ NEW METHOD
    _checkPeerStatus(); // Check online status + fetch profile immediately
    _pingTimer = Timer.periodic(const Duration(seconds: 45), (_) => _checkPeerStatus());
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
      // A successful send/receive proves the peer is online —
      // but only if the probe hasn't confirmed them offline.
      // A fresh message delivery overrides the probe result.
      if (mounted && _peerOnline != true && !_probeConfirmedOffline) {
        _failedPings = 0;
        _probeConfirmedOffline = false;
        setState(() => _peerOnline = true);
      }
    });

    await _loadInitialMessages();

    if (mounted && _messages.messages.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
        }
      });
    }

    // ✅ Start ChatService background tasks
    _chatService.startPolling();
    _chatService.startSendQueue();
  }

  // ✅ NEW: Handle incoming messages from ChatService
  void _handleNewMessages(List<Map<String, dynamic>> rawMessages) async {
    if (!mounted) return;

    // Don't mark online from DB messages — _reachableSub handles
    // genuinely fresh peer messages already.

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
    } catch (e) {
      debugPrint('Error handling new messages: $e');
    }
  }

  // ✅ NEW: Handle message status updates
  void _handleStatusUpdate(MessageStatusUpdate update) {
    if (!mounted) return;

    final idx = _messages.messages.indexWhere((m) => m.id == update.messageId);
    if (idx != -1) {
      setState(() {
        final msg = _messages.messages[idx];

        if (update.status == 'read') {
          _messages.updateMessage(msg, msg.copyWith(seenAt: DateTime.now()));
        } else if (update.status == 'failed') {
          _messages.updateMessage(msg, msg.copyWith(
            metadata: {...?msg.metadata, 'failed': true},
          ));
        } else if (update.status == 'pending') {
          // Resend in progress — clear failed flag
          _messages.updateMessage(msg, msg.copyWith(
            metadata: {...?msg.metadata, 'failed': false},
          ));
        }
      });
    }
  }

  @override
  void dispose() {
    // ✅ DISPOSE ChatService
    _chatService.dispose();
    _newMessagesSub?.cancel();
    _statusSub?.cancel();
    _reachableSub?.cancel();
    _pingTimer?.cancel();

    _debounceTimer?.cancel();
    _scrollController.removeListener(_scrollListener);
    _scrollController.dispose();
    super.dispose();
  }

  /// Check peer status by calling /profile — determines online/offline
  /// AND fetches fresh name/avatar in one round-trip.
  Future<void> _checkPeerStatus() async {
    final client = TorHttpClient(proxyHost: '127.0.0.1', proxyPort: 9050);
    try {
      final uri = Uri.parse('http://${widget.peerId}:80/profile');
      final response = await client.get(uri, {}).timeout(const Duration(seconds: 20));
      final body = await response.transform(utf8.decoder).join();
      final data = jsonDecode(body) as Map<String, dynamic>;

      if (!mounted) return;

      // Peer responded — they're online
      _failedPings = 0;
      _probeConfirmedOffline = false;
      if (_peerOnline != true) {
        setState(() => _peerOnline = true);
      }

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
      debugPrint('Profile check failed: $e');
      if (mounted) {
        _failedPings++;
        final errStr = e.toString();
        // hostUnreachable / connection refused = peer is definitely offline
        final isHardFailure = errStr.contains('hostUnreachable') ||
            errStr.contains('connectionRefused') ||
            errStr.contains('ttlExpired');
        if (isHardFailure) {
          _probeConfirmedOffline = true;
          if (_peerOnline != false) {
            setState(() => _peerOnline = false);
          }
        } else if (_failedPings >= 3 && _peerOnline != false) {
          _probeConfirmedOffline = true;
          setState(() => _peerOnline = false);
        }
      }
    } finally {
      client.close();
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

      setState(() {
        resetChatState();
        _chatKey = UniqueKey();
        _peerName = widget.peerName;
        _peerAvatarBase64 = widget.peerAvatarBase64;
        _peerOnline = null;
        _failedPings = 0;
        _probeConfirmedOffline = false;
      });

      _chatService = ChatService(
        userId: widget.userId,
        peerId: widget.peerId,
        keyManager: widget.keyManager,
      );

      _initializeChat();
      _checkPeerStatus();
      _pingTimer = Timer.periodic(const Duration(seconds: 45), (_) => _checkPeerStatus());
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
      try {
        if (msg['type'] == 'text') {
          messages.add(
            TextMessage(
              authorId: User(id: msg['senderId']).id,
              createdAt: DateTime.fromMillisecondsSinceEpoch(msg['timestamp']),
              id: msg['id'],
              replyToMessageId: msg['replyTo'],
              seenAt: msg['readAt'] != null
                  ? DateTime.fromMillisecondsSinceEpoch(msg['readAt'])
                  : null,
              text: keyManager.decryptMessage(msg['message']),
            ),
          );
        } else if (msg['type'] == 'file') {
          messages.add(
            FileMessage(
              id: msg['id'],
              authorId: User(id: msg['senderId']).id,
              createdAt: DateTime.fromMillisecondsSinceEpoch(msg['timestamp']),
              replyToMessageId: msg['replyTo'],
              name: msg['fileName'] ?? "Unknown",
              size: msg['fileSize'] ?? 0,
              seenAt: msg['readAt'] != null
                  ? DateTime.fromMillisecondsSinceEpoch(msg['readAt'] as int)
                  : null,
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
              seenAt: msg['readAt'] != null
                  ? DateTime.fromMillisecondsSinceEpoch(msg['readAt'] as int)
                  : null,
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
                seenAt: msg['readAt'] != null
                    ? DateTime.fromMillisecondsSinceEpoch(msg['readAt'] as int)
                    : null,
                source: "",
                metadata: {'viewOnce': true, 'viewed': true},
              ),
            );
          } else {
            messages.add(
              ImageMessage(
                id: msg['id'],
                authorId: User(id: msg['senderId']).id,
                createdAt: DateTime.fromMillisecondsSinceEpoch(msg['timestamp']),
                replyToMessageId: msg['replyTo'],
                size: msg['fileSize'] ?? 0,
                seenAt: msg['readAt'] != null
                    ? DateTime.fromMillisecondsSinceEpoch(msg['readAt'] as int)
                    : null,
                source:
                    "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==",
                metadata: isViewOnce ? {'viewOnce': true, 'viewed': false} : null,
              ),
            );

            if (!isViewOnce) {
              decryptFileInBackground(msg, keyManager).then((decryptedBytes) {
                final index = messages.indexWhere((m) => m.id == msg['id']);
                if (index != -1) {
                  final oldMessage = messages[index] as ImageMessage;
                  final newMessage = oldMessage.copyWith(
                    source: "data:image/png;base64,${base64Encode(decryptedBytes)}",
                    size: decryptedBytes.length,
                  );
                  setState(() {
                    messages[index] = newMessage;
                  });
                }
              });
            }
          }
        }
      } catch (e) {
        print(e);
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
    return messages;
  }

  Future<Uint8List> decryptFileInBackground(
    Map<String, dynamic> msg,
    KeyManager keyManager,
  ) async {
    final hybrid = jsonDecode(msg['message']);
    final rsaEncryptedAesKey = hybrid['aes_key'];
    final iv = e.IV.fromBase64(hybrid['iv']);
    final encryptedData = base64Decode(hybrid['data']);
    final aesKeyBytes = keyManager.decryptMyMessageBytes(rsaEncryptedAesKey);
    final aesKey = e.Key(Uint8List.fromList(aesKeyBytes));
    final decryptedBytes = AESHelper.decryptBytes(encryptedData, aesKey, iv);
    return decryptedBytes;
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
        TextMessage(
          authorId: _user.id,
          createdAt: DateTime.now(),
          id: messageId,
          text: text,
          sentAt: DateTime.now(), // Optimistic: show single tick
          replyToMessageId: replyToId,
        ),
        index: _messages.messages.length,
      );
      _replyToMessage = null;
    });

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
          FileMessage(
            authorId: _user.id,
            createdAt: DateTime.now(),
            id: messageId,
            name: fileName,
            size: bytes.length,
            replyToMessageId: replyToId,
            source: base64Encode(bytes),
            sentAt: DateTime.now(),
          ),
          index: _messages.messages.length,
        );
      } else if (type == "image") {
        _messages.insertMessage(
          ImageMessage(
            authorId: _user.id,
            createdAt: DateTime.now(),
            id: messageId,
            size: bytes.length,
            replyToMessageId: replyToId,
            source: "data:image/png;base64,${base64Encode(bytes.toList())}",
            sentAt: DateTime.now(),
            metadata: viewOnce ? {'viewOnce': true, 'viewed': false} : null,
          ),
          index: _messages.messages.length,
        );
      }
      _replyToMessage = null;
    });

    // ✅ NOW send in background
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

    // Show bottom sheet to choose normal or view-once
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
              subtitle: const Text('Photo disappears after viewing'),
              onTap: () => Navigator.pop(ctx, true),
            ),
          ],
        ),
      ),
    );

    if (viewOnce == null) return; // dismissed

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
          isOnline: _peerOnline ?? false,
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
            await DBHelper.deleteUser(widget.peerId);
            resetChatState();
            setState(() {
              _messages = InMemoryChatController();
              _chatKey = UniqueKey();
              _replyToMessage = null;
            });
            widget.clearChat();
          },
        ),
      ),
    );

    if (result != null && result is Contact) {
      setState(() => _peerName = result.displayName);
    }
  }

  Widget _buildReplyPreview() {
    if (_replyToMessage == null) return SizedBox.shrink();
    String previewText;
    if (_replyToMessage is TextMessage) {
      previewText = (_replyToMessage as TextMessage).text;
    } else if (_replyToMessage is ImageMessage) {
      previewText = '📷 Image';
    } else if (_replyToMessage is FileMessage) {
      previewText = '📎 File: ${(_replyToMessage as FileMessage).name}';
    } else {
      previewText = 'Unsupported message';
    }
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

  static final _urlRegex = RegExp(
    r'https?://[^\s<>\[\]{}|\\^`]+',
    caseSensitive: false,
  );

  Widget _buildLinkedText(String text, Color textColor, double fontSize) {
    final matches = _urlRegex.allMatches(text).toList();
    if (matches.isEmpty) {
      return Text(text, style: TextStyle(color: textColor, fontSize: fontSize));
    }

    final spans = <InlineSpan>[];
    int lastEnd = 0;

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

  void _showMessageMenu(BuildContext context, Message message, Offset position) {
    final text = _getMessageText(message);
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;

    showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(position.dx, position.dy, 0, 0),
        Offset.zero & overlay.size,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      items: [
        if (text.isNotEmpty)
          PopupMenuItem(
            value: 'copy',
            child: Row(
              children: [
                Icon(Icons.copy, size: 20, color: Theme.of(context).iconTheme.color),
                const SizedBox(width: 12),
                const Text('Copy'),
              ],
            ),
          ),
        PopupMenuItem(
          value: 'reply',
          child: Row(
            children: [
              Icon(Icons.reply, size: 20, color: Theme.of(context).iconTheme.color),
              const SizedBox(width: 12),
              const Text('Reply'),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'select',
          child: Row(
            children: [
              Icon(Icons.check_circle_outline, size: 20, color: Theme.of(context).iconTheme.color),
              const SizedBox(width: 12),
              const Text('Select'),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'delete',
          child: Row(
            children: [
              Icon(Icons.delete_outline, size: 20, color: Colors.red),
              const SizedBox(width: 12),
              const Text('Delete', style: TextStyle(color: Colors.red)),
            ],
          ),
        ),
      ],
    ).then((value) {
      if (value == null) return;
      switch (value) {
        case 'copy':
          Clipboard.setData(ClipboardData(text: text));
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Copied to clipboard'), duration: Duration(seconds: 1)),
          );
          break;
        case 'reply':
          setState(() => _replyToMessage = message);
          break;
        case 'select':
          setState(() => selectedMessageIds.add(message.id));
          break;
        case 'delete':
          _deleteMessage(message);
          break;
      }
    });
  }

  Future<void> _deleteMessage(Message message) async {
    await MessagesDb.deleteMessageById(message.id);
    setState(() {
      _messages.removeMessage(message);
      selectedMessageIds.remove(message.id);
    });
  }

  void _resendMessage(Message message) {
    _chatService.resendMessage(message.id);
  }

  /// Build tick/status widget for sent messages. Shows ⚠ for failed.
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

  Future<void> deleteSelectedMessages() async {
    for (var id in selectedMessageIds) {
      await MessagesDb.deleteMessageById(id);
    }

    setState(() {
      for (var id in selectedMessageIds) {
        _messages.removeMessage(
          _messages.messages.firstWhere((msg) => msg.id == id),
        );
      }
      selectedMessageIds.clear();
    });
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
              ContactAvatar(name: _peerName, radius: 20, avatarBase64: _peerAvatarBase64),
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
        child: Column(
          children: [
            if (_replyToMessage != null) _buildReplyPreview(),

            Expanded(
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
                            String previewText;
                            if (repliedMessage is TextMessage) {
                              previewText = repliedMessage.text;
                            } else if (repliedMessage is ImageMessage) {
                              previewText = '📷 Image';
                            } else if (repliedMessage is FileMessage) {
                              previewText = '📎 File: ${repliedMessage.name}';
                            } else {
                              previewText = 'Unsupported message';
                            }

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
                                  if (_dragOffsets[message.id]! < 0)
                                    _dragOffsets[message.id] = 0;
                                  if (_dragOffsets[message.id]! > 100)
                                    _dragOffsets[message.id] = 100;
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
                                                child,
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
                    return (Padding(padding: EdgeInsetsGeometry.infinity));
                  },
                ),
              ),
            ),

            MessageComposer(
              onSendText: _handleSend,
              onSendImage: _handleSendImage,
              onSendFile: _handleSendFile,
              onSendVoice: _handleSendVoice,
            ),
          ],
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
                if (!mounted) return;
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

    // Normal image
    final base64Str = message.source.contains('base64,')
        ? message.source.split('base64,')[1]
        : message.source;

    Uint8List bytes = base64Decode(base64Str);

    return Column(
      crossAxisAlignment: isSentByMe
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      children: [
        GestureDetector(
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => Scaffold(
                  backgroundColor:
                      Theme.of(context).brightness == Brightness.dark
                      ? Colors.black
                      : Colors.white,
                  appBar: AppBar(
                    backgroundColor: Colors.transparent,
                    elevation: 0,
                  ),
                  body: Center(
                    child: InteractiveViewer(child: Image.memory(bytes)),
                  ),
                ),
              ),
            );
          },
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.memory(
              width: max(200, (message.width ?? 20) / 4),
              height: max(200, (message.height ?? 20) / 4),
              bytes,
              fit: BoxFit.cover,
            ),
          ),
        ),
        const SizedBox(height: 4),
        // ✅ Time + Tick indicators
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              timeString,
              style: TextStyle(fontSize: 10, color: Colors.grey[600]),
            ),
            if (isSentByMe) ...[const SizedBox(width: 4), tickWidget],
          ],
        ),
      ],
    );
  }

  Widget fileMessageBuilder(
    BuildContext context,
    FileMessage message,
    int index, {
    required bool isSentByMe,
    MessageGroupStatus? groupStatus,
  }) {
    // Detect voice messages
    if (message.name.contains('voice_message') || message.source.startsWith('audio:')) {
      return _voiceMessageBuilder(context, message, index, isSentByMe: isSentByMe);
    }

    final maxWidth = MediaQuery.of(context).size.width * 0.4;
    final ValueNotifier<bool> isDownloading = ValueNotifier(false);

    Future<void> downloadBase64File() async {
      if (isDownloading.value == true) return;

      isDownloading.value = true;

      await Future.delayed(Duration(milliseconds: 50));
      try {
        if (message.source.isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('No encrypted data available for this file'),
            ),
          );
          return;
        }

        final Map<String, dynamic> decryptInput = {'message': message.source};

        Uint8List bytes = await decryptFileInBackground(
          decryptInput,
          widget.keyManager,
        );

        Directory? dir;

        if (Platform.isAndroid) {
          dir = Directory("/storage/emulated/0/Download/");
        } else {
          dir = await getDownloadsDirectory();
        }
        File file = File('${dir!.path}/${message.name}');
        int c = 0;
        while (await file.exists()) {
          file = File('${dir.path}/${message.name} - $c');
          c++;
        }
        if (bytes.isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                '${file.path.split("/").last} is still decrypting, please wait.',
              ),
            ),
          );
          return;
        }
        await file.writeAsBytes(bytes);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Successfully downloaded ${file.path.split("/").last}',
            ),
          ),
        );
      } catch (e) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error downloading file: $e')));
      } finally {
        isDownloading.value = false;
      }
    }

    final msgDate = DateTime.fromMillisecondsSinceEpoch(
      message.createdAt!.millisecondsSinceEpoch,
    );
    final timeString =
        "${msgDate.hour.toString().padLeft(2, '0')}:${msgDate.minute.toString().padLeft(2, '0')}";

    String fileSizeString = '';
    if (message.size != null) {
      final sizeInKB = message.size! / 1024;
      if (sizeInKB < 1024) {
        fileSizeString = "${sizeInKB.toStringAsFixed(1)} KB";
      } else {
        fileSizeString = "${(sizeInKB / 1024).toStringAsFixed(1)} MB";
      }
    }

    // ✅ Determine tick status
    Widget tickWidget = const SizedBox.shrink();
    if (isSentByMe) {
      final tickColor = Theme.of(context).colorScheme.onPrimary;
      tickWidget = _buildStatusWidget(message, isSentByMe, tickColor.withAlpha(220));
    }

    return Column(
      crossAxisAlignment: isSentByMe
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      children: [
        ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: GestureDetector(
            onTap: downloadBase64File,
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary.withAlpha(225),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ValueListenableBuilder<bool>(
                    valueListenable: isDownloading,
                    builder: (context, downloading, _) {
                      if (downloading) {
                        return SizedBox(
                          width: 36,
                          height: 36,
                          child: CircularProgressIndicator(
                            valueColor: AlwaysStoppedAnimation<Color>(
                              Theme.of(context).colorScheme.onPrimary,
                            ),
                            strokeWidth: 2.5,
                          ),
                        );
                      } else {
                        return CircleAvatar(
                          backgroundColor: Theme.of(
                            context,
                          ).colorScheme.primary.withAlpha(120),
                          child: Icon(
                            Icons.insert_drive_file,
                            size: 24,
                            color: Theme.of(context).colorScheme.onPrimary,
                          ),
                        );
                      }
                    },
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          message.name,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.onPrimary,
                          ),
                          overflow: TextOverflow.visible,
                        ),
                        // ✅ File size + Time + Tick indicators
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            if (fileSizeString.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(right: 4),
                                child: Text(
                                  fileSizeString,
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: Theme.of(context).colorScheme.onPrimary.withAlpha(180),
                                  ),
                                ),
                              ),
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  timeString,
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: Theme.of(context).colorScheme.onPrimary.withAlpha(180),
                                  ),
                                ),
                                if (isSentByMe) ...[
                                  const SizedBox(width: 4),
                                  tickWidget,
                                ],
                              ],
                            ),
                          ],
                        ),
                      ],
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
            // ✅ Text with clickable links
            _buildLinkedText(
              message.text,
              isSentByMe
                  ? Theme.of(context).colorScheme.onPrimary
                  : Theme.of(context).colorScheme.onSecondary,
              14,
            ),
            const SizedBox(height: 4),
            // ✅ Time and ticks aligned to the right
            Align(
              alignment: Alignment.centerRight,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
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

    return _VoiceMessageBubble(
      message: message,
      isSentByMe: isSentByMe,
      timeString: timeString,
      tickWidget: tickWidget,
      keyManager: widget.keyManager,
    );
  }
}

/// Stateful widget for voice message playback with its own AudioPlayer
class _VoiceMessageBubble extends StatefulWidget {
  final FileMessage message;
  final bool isSentByMe;
  final String timeString;
  final Widget tickWidget;
  final KeyManager keyManager;

  const _VoiceMessageBubble({
    required this.message,
    required this.isSentByMe,
    required this.timeString,
    required this.tickWidget,
    required this.keyManager,
  });

  @override
  State<_VoiceMessageBubble> createState() => _VoiceMessageBubbleState();
}

class _VoiceMessageBubbleState extends State<_VoiceMessageBubble> {
  // audioplayers for mobile; Process-based for Linux desktop
  AudioPlayer? _player;
  Process? _linuxProcess;
  Timer? _positionTimer;
  bool _isPlaying = false;
  bool _isLoading = false;
  bool _hasCompleted = false; // track if playback finished
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  Uint8List? _audioBytes;
  String? _resolvedPath; // cached file path for replay

  bool get _useNativePlayback => Platform.isLinux || Platform.isMacOS || Platform.isWindows;

  @override
  void initState() {
    super.initState();

    // Parse duration from audio marker (own-sent messages)
    if (widget.message.source.startsWith('audio:')) {
      final parts = widget.message.source.split(':');
      if (parts.length >= 2) {
        final ms = int.tryParse(parts[1]) ?? 0;
        _duration = Duration(milliseconds: ms);
      }
    }

    if (!_useNativePlayback) {
      _player = AudioPlayer();
      _player!.onPlayerStateChanged.listen((state) {
        if (mounted) {
          setState(() => _isPlaying = state == PlayerState.playing);
        }
      });
      _player!.onPositionChanged.listen((pos) {
        if (mounted) setState(() => _position = pos);
      });
      _player!.onDurationChanged.listen((dur) {
        if (mounted) setState(() => _duration = dur);
      });
      _player!.onPlayerComplete.listen((_) {
        if (mounted) setState(() {
          _isPlaying = false;
          _hasCompleted = true;
          _position = Duration.zero;
        });
      });
    }
  }

  @override
  void dispose() {
    _player?.dispose();
    _positionTimer?.cancel();
    _linuxProcess?.kill();
    super.dispose();
  }

  Future<String?> _resolvePath() async {
    if (_resolvedPath != null) return _resolvedPath;

    if (widget.message.source.startsWith('audio:')) {
      final parts = widget.message.source.split(':');
      if (parts.length >= 3) {
        final filePath = parts.sublist(2).join(':');
        final file = File(filePath);
        if (await file.exists()) {
          _audioBytes = Uint8List(0);
          _resolvedPath = filePath;
          return _resolvedPath;
        }
      }
      return null;
    }

    // Received message — decrypt
    final hybrid = jsonDecode(widget.message.source);
    final rsaEncryptedAesKey = hybrid['aes_key'];
    final iv = e.IV.fromBase64(hybrid['iv']);
    final encryptedData = base64Decode(hybrid['data']);
    final aesKeyBytes = widget.keyManager.decryptMyMessageBytes(rsaEncryptedAesKey);
    final aesKey = e.Key(Uint8List.fromList(aesKeyBytes));
    _audioBytes = AESHelper.decryptBytes(encryptedData, aesKey, iv);

    // Estimate duration from WAV data if not already known
    if (_duration == Duration.zero && _audioBytes!.length > 44) {
      // WAV: 16kHz, mono, 16-bit PCM → 32000 bytes/sec
      final dataSize = _audioBytes!.length - 44; // skip WAV header
      final durationMs = (dataSize / 32000 * 1000).round();
      _duration = Duration(milliseconds: durationMs);
    }

    final dir = await getTemporaryDirectory();
    final ext = widget.message.name.split('.').last;
    final tmpFile = File('${dir.path}/voice_${widget.message.id}.$ext');
    await tmpFile.writeAsBytes(_audioBytes!);
    _resolvedPath = tmpFile.path;
    return _resolvedPath;
  }

  Future<void> _playFromFile() async {
    final playPath = await _resolvePath();
    if (playPath == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Voice message cache expired')),
        );
      }
      return;
    }

    if (_useNativePlayback) {
      await _playNative(playPath);
    } else {
      _hasCompleted = false;
      await _player!.play(DeviceFileSource(playPath));
    }
  }

  Future<void> _togglePlayback() async {
    if (_isPlaying) {
      if (_useNativePlayback) {
        _linuxProcess?.kill();
        _linuxProcess = null;
        _positionTimer?.cancel();
        setState(() => _isPlaying = false);
      } else {
        await _player!.pause();
      }
      return;
    }

    // Mobile: if completed or not yet loaded, play from file
    if (!_useNativePlayback && _resolvedPath != null && !_hasCompleted) {
      // Paused — resume
      await _player!.resume();
      return;
    }

    setState(() => _isLoading = true);

    try {
      await _playFromFile();
    } catch (err) {
      debugPrint('Voice playback error: $err');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to play voice message')),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _seekTo(Duration position) async {
    if (_useNativePlayback) return; // can't seek native process
    if (_player != null) {
      await _player!.seek(position);
      setState(() => _position = position);
    }
  }

  Future<void> _playNative(String path) async {
    // Kill any previous playback
    _linuxProcess?.kill();
    _positionTimer?.cancel();

    String? cmd;
    List<String> args;

    if (Platform.isLinux) {
      for (final candidate in ['paplay', 'aplay', 'ffplay']) {
        final result = await Process.run('which', [candidate]);
        if (result.exitCode == 0) {
          cmd = candidate;
          break;
        }
      }
      if (cmd == null) {
        throw Exception('No audio player found. Install pulseaudio-utils, alsa-utils, or ffmpeg.');
      }
      args = cmd == 'ffplay' ? ['-nodisp', '-autoexit', path] : [path];
    } else if (Platform.isMacOS) {
      cmd = 'afplay';
      args = [path];
    } else {
      cmd = 'powershell';
      args = ['-c', '(New-Object Media.SoundPlayer "$path").PlaySync()'];
    }

    _linuxProcess = await Process.start(cmd, args);
    setState(() => _isPlaying = true);

    final startTime = DateTime.now();
    _positionTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (!mounted) return;
      final elapsed = DateTime.now().difference(startTime);
      if (_duration > Duration.zero && elapsed > _duration) {
        // Don't overshoot
        setState(() => _position = _duration);
      } else {
        setState(() => _position = elapsed);
      }
    });

    _linuxProcess!.exitCode.then((_) {
      _positionTimer?.cancel();
      if (mounted) {
        setState(() {
          _isPlaying = false;
          _position = Duration.zero;
        });
      }
      _linuxProcess = null;
    });
  }

  String _formatDuration(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final maxWidth = MediaQuery.of(context).size.width * 0.65;
    final bubbleColor = widget.isSentByMe
        ? Theme.of(context).colorScheme.primary.withAlpha(225)
        : Theme.of(context).colorScheme.secondary.withAlpha(225);
    final contentColor = widget.isSentByMe
        ? Theme.of(context).colorScheme.onPrimary
        : Theme.of(context).colorScheme.onSecondary;

    final progress = _duration.inMilliseconds > 0
        ? _position.inMilliseconds / _duration.inMilliseconds
        : 0.0;

    return Column(
      crossAxisAlignment: widget.isSentByMe
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      children: [
        ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: bubbleColor,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Play/pause button
                _isLoading
                    ? SizedBox(
                        width: 36,
                        height: 36,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.5,
                          valueColor: AlwaysStoppedAnimation(contentColor),
                        ),
                      )
                    : IconButton(
                        icon: Icon(
                          _isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                          color: contentColor,
                          size: 28,
                        ),
                        onPressed: _togglePlayback,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                      ),
                const SizedBox(width: 8),
                // Seekable progress slider
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SliderTheme(
                        data: SliderThemeData(
                          trackHeight: 4,
                          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                          overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                          activeTrackColor: contentColor.withAlpha(200),
                          inactiveTrackColor: contentColor.withAlpha(60),
                          thumbColor: contentColor,
                          overlayColor: contentColor.withAlpha(30),
                        ),
                        child: Slider(
                          value: progress.clamp(0.0, 1.0),
                          onChanged: (val) {
                            if (_duration > Duration.zero) {
                              final newPos = Duration(milliseconds: (val * _duration.inMilliseconds).round());
                              _seekTo(newPos);
                            }
                          },
                          onChangeEnd: (val) {
                            if (_duration > Duration.zero && !_useNativePlayback) {
                              final newPos = Duration(milliseconds: (val * _duration.inMilliseconds).round());
                              _seekTo(newPos);
                            }
                          },
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              _formatDuration(_isPlaying || _position > Duration.zero ? _position : _duration),
                              style: TextStyle(fontSize: 11, color: contentColor.withAlpha(180)),
                            ),
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  widget.timeString,
                                  style: TextStyle(fontSize: 10, color: contentColor.withAlpha(180)),
                                ),
                                if (widget.isSentByMe) ...[
                                  const SizedBox(width: 4),
                                  widget.tickWidget,
                                ],
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
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
