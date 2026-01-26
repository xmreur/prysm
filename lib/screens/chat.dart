import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:encrypt/encrypt.dart' as e;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_chat_ui/flutter_chat_ui.dart';
import 'package:flutter_chat_core/flutter_chat_core.dart';
import 'package:path_provider/path_provider.dart';
import 'package:prysm/database/messages.dart';
import 'package:prysm/screens/chat_profile_screen.dart';
import 'package:prysm/screens/message_composer.dart';
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
  final TorManager torManager;
  final KeyManager keyManager;
  final String? peerPublicKeyPem;
  final int currentTheme;
  final Function() clearChat;
  final Function() reloadUsers;

  const ChatScreen({
    required this.userId,
    required this.userName,
    required this.peerId,
    required this.peerName,
    required this.torManager,
    required this.keyManager,
    this.peerPublicKeyPem,
    this.currentTheme = 0,
    required this.clearChat,
    required this.reloadUsers,
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
  // ignore: unused_field
  int _currentTheme = 0;

  Set<String> selectedMessageIds = {};
  Message? _replyToMessage;
  Map<String, double> _dragOffsets = {};

  Key _chatKey = UniqueKey();
  final AutoScrollController _scrollController = AutoScrollController();
  Timer? _debounceTimer;

  // ✅ ADD ChatService subscriptions
  StreamSubscription? _newMessagesSub;
  StreamSubscription? _statusSub;

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
    _user = User(id: widget.userId);

    // ✅ INITIALIZE ChatService
    _chatService = ChatService(
      userId: widget.userId,
      peerId: widget.peerId,
      keyManager: widget.keyManager,
    );

    _scrollController.addListener(_scrollListener);
    _initializeChat(); // ✅ NEW METHOD
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

        // ✅ Only handle 'read' - 'sent' is already set optimistically
        if (update.status == 'read') {
          _messages.updateMessage(msg, msg.copyWith(seenAt: DateTime.now()));
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

    _debounceTimer?.cancel();
    _scrollController.removeListener(_scrollListener);
    _scrollController.dispose();
    super.dispose();
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

      setState(() {
        resetChatState();
        _chatKey = UniqueKey();
      });

      _chatService = ChatService(
        userId: widget.userId,
        peerId: widget.peerId,
        keyManager: widget.keyManager,
      );

      _initializeChat();
    }

    if (oldWidget.currentTheme != widget.currentTheme) {
      setState(() => _currentTheme = widget.currentTheme);
    }
    if (oldWidget.peerName != widget.peerName) {
      setState(() => _peerName = widget.peerName);
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
        } else if (msg['type'] == "image") {
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
            ),
          );

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

  Future<void> _sendFile(Uint8List bytes, String fileName, String type) async {
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
      }
    }

    _sendFile(bytes, pickedFile.name, "image");
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

  // ==================== UI HELPERS (KEEP AS-IS) ====================

  void _openChatProfile() async {
    final peerContact = Contact(
      id: widget.peerId,
      name: _peerName,
      avatarUrl: '',
      publicKeyPem: widget.peerPublicKeyPem ?? '',
    );

    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ChatProfileScreen(
          peer: peerContact,
          currentUserName: widget.userName,
          onClose: () => Navigator.of(context).pop(),
          onUpdateName: (Contact updatedContact) async {
            await DBHelper.insertOrUpdateUser({
              'id': updatedContact.id,
              'name': updatedContact.name,
              'avatarUrl': updatedContact.avatarUrl,
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
      setState(() => _peerName = result.name);
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
                          color: Colors.grey[300],
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      ListTile(
                        leading: CircleAvatar(
                          radius: 20,
                          backgroundColor: Theme.of(
                            context,
                          ).primaryColor.withValues(alpha: 0.1),
                          child: Text(
                            _peerName.isNotEmpty
                                ? _peerName[0].toUpperCase()
                                : 'U',
                            style: TextStyle(
                              color: Theme.of(context).primaryColor,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
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
              CircleAvatar(
                radius: 20,
                backgroundColor: Theme.of(
                  context,
                ).primaryColor.withValues(alpha: 0.8),
                child: Text(
                  _peerName.isNotEmpty ? _peerName[0].toUpperCase() : 'U',
                  style: TextStyle(
                    color: Theme.of(context).brightness == Brightness.dark
                        ? Theme.of(context).hintColor
                        : Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
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
                  Text(
                    'GHOST',
                    style: TextStyle(
                      color: Theme.of(context).brightness == Brightness.dark
                          ? Theme.of(context).hintColor
                          : Theme.of(context).primaryColor,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
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
                onMessageLongPress:
                    (
                      context,
                      message, {
                      LongPressStartDetails? details,
                      int? index,
                    }) {
                      setState(() {
                        if (selectedMessageIds.contains(message.id)) {
                          selectedMessageIds.remove(message.id);
                        } else {
                          selectedMessageIds.add(message.id);
                        }
                      });
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
                                color: Colors.grey.shade200,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              constraints: BoxConstraints(
                                maxWidth:
                                    MediaQuery.of(context).size.width * 0.7,
                              ),
                              child: Text(
                                previewText,
                                style: const TextStyle(
                                  fontStyle: FontStyle.italic,
                                  color: Colors.black54,
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
                              onLongPress: () {
                                setState(() {
                                  if (isSelected) {
                                    selectedMessageIds.remove(message.id);
                                  } else {
                                    selectedMessageIds.add(message.id);
                                  }
                                });
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
                                        ? Colors.blue.withAlpha(60)
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
    final base64Str = message.source.contains('base64,')
        ? message.source.split('base64,')[1]
        : message.source;

    Uint8List bytes = base64Decode(base64Str);

    final msgDate = DateTime.fromMillisecondsSinceEpoch(
      message.createdAt!.millisecondsSinceEpoch,
    );
    final timeString =
        "${msgDate.hour.toString().padLeft(2, '0')}:${msgDate.minute.toString().padLeft(2, '0')}";

    // ✅ Determine tick status
    Widget tickWidget = const SizedBox.shrink();
    if (isSentByMe) {
      if (message.seenAt != null) {
        // Double tick (read)
        tickWidget = Icon(
          Icons.done_all,
          size: 14,
          color: Colors.blue.shade700,
        );
      } else if (message.sentAt != null) {
        // Single tick (sent)
        tickWidget = Icon(Icons.done, size: 14, color: Colors.grey[600]);
      }
    }

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
      if (message.seenAt != null) {
        // Double tick (read)
        tickWidget = Icon(
          Icons.done_all,
          size: 14,
          color: Colors.blue.shade700,
        );
      } else if (message.sentAt != null) {
        // Single tick (sent)
        tickWidget = Icon(Icons.done, size: 14, color: Colors.grey[600]);
      }
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
                              Theme.of(context).brightness == Brightness.dark
                                  ? Colors.white
                                  : Colors.black,
                            ),
                            strokeWidth: 2.5,
                          ),
                        );
                      } else {
                        return CircleAvatar(
                          backgroundColor: Theme.of(
                            context,
                          ).primaryColor.withAlpha(120),
                          child: Icon(
                            Icons.insert_drive_file,
                            size: 24,
                            color:
                                Theme.of(context).brightness == Brightness.dark
                                ? Colors.grey[300]
                                : Colors.white,
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
                            color:
                                Theme.of(context).brightness == Brightness.dark
                                ? Colors.black
                                : Colors.white,
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
                                    color:
                                        Theme.of(context).brightness ==
                                            Brightness.dark
                                        ? Colors.grey[900]
                                        : Colors.white,
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
                                    color:
                                        Theme.of(context).brightness ==
                                            Brightness.dark
                                        ? Colors.grey[900]
                                        : Colors.white,
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
      if (message.seenAt != null) {
        // Double tick (read) - BLUE
        tickWidget = Icon(
          Icons.done_all,
          size: 14,
          color: Colors.blue.shade700,
        );
      } else if (message.sentAt != null) {
        // Single tick (sent) - GREY
        tickWidget = Icon(Icons.done, size: 14, color: Colors.grey[600]);
      }
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
            // ✅ Text stays left-aligned
            Text(
              message.text,
              style: TextStyle(
                color: Theme.of(context).brightness == Brightness.dark
                    ? Colors.black
                    : Colors.white,
                fontSize: 14,
              ),
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
                      color: Theme.of(context).brightness == Brightness.dark
                          ? Colors.grey[900]
                          : Colors.white70,
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
}
