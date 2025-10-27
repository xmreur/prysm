import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:bs58/bs58.dart';
import 'package:encrypt/encrypt.dart' as e;
import 'package:flutter/material.dart';
import 'package:open_file/open_file.dart';
import 'package:flutter_chat_ui/flutter_chat_ui.dart';
import 'package:flutter_chat_core/flutter_chat_core.dart';
import 'package:path_provider/path_provider.dart' show getDownloadsDirectory, getTemporaryDirectory;
// import 'package:http/http.dart' as http;
import 'package:pointycastle/asymmetric/api.dart';
import 'package:prysm/screens/chat_profile_screen.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/util/file_encrypt.dart';
import 'package:prysm/util/message_db_helper.dart';
import 'package:prysm/util/pending_message_db_helper.dart';
import 'package:prysm/util/rsa_helper.dart';
import 'package:prysm/util/tor_service.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/message_http_client.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:scroll_to_index/scroll_to_index.dart';
import 'package:prysm/models/contact.dart';
import 'dart:typed_data';

import 'package:uuid/uuid.dart';


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
    Key? key,
  }) : super(key: key);

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  var _messages = InMemoryChatController();
  final Map<String, TextMessage> _messageCache = {};
  late final User _user;
  bool _loading = false;
  bool _hasMore = true;
  int? _oldestTimestamp;
  String? _oldestMessageId;
  int? _newestTimestamp;

  RSAPublicKey? _peerPublicKey;

  String _peerName = '';
  int _currentTheme = 0;
  int _lastMessageCount = 0;

  Message? _replyToMessage;
  
  Map<String, double> _dragOffsets = {}; // messageId -> offset

  Key _chatKey = UniqueKey();
  final AutoScrollController _scrollController = AutoScrollController();
  Timer? _debounceTimer;
  Timer? _retryTimer;

  void _scrollListener() {
    // LOAD WHEN NEAR TOP (not bottom)
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
    _fetchPeerPublicKey().then((_) {
      _loadInitialMessages();
      _startPolling();
    });
    _scrollController.addListener(_scrollListener);
    startOutgoingSender();
  }

  @override
  void dispose() {
    _retryTimer?.cancel();
    _debounceTimer?.cancel();
    _scrollController.removeListener(_scrollListener);
    super.dispose();
  }

  void resetChatState() {
    _messages = InMemoryChatController();
    _replyToMessage = null;
    _messageCache.clear();
    _oldestTimestamp = null;
    _oldestMessageId = null;
    _newestTimestamp = null;
    _hasMore = true;
    _loading = false;
    // (Reset any other relevant per-chat state here!)
  }

  @override
  void didUpdateWidget(covariant ChatScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.peerId != widget.peerId) {
      // Chat peer changed!
      // print("CHANGED CHAT: ${oldWidget.peerId} -> ${widget.peerId}");
      setState(() {
        resetChatState();
        _chatKey = UniqueKey();
      });
      _fetchPeerPublicKey().then((_) => _loadInitialMessages());
    }
    // For theme/name change, update without full reset
    if (oldWidget.currentTheme != widget.currentTheme) {
      setState(() {
        _currentTheme = widget.currentTheme;
      });
    }
    if (oldWidget.peerName != widget.peerName) {
      setState(() {
        _peerName = widget.peerName;
      });
    }
  }


  void startOutgoingSender() async {
      _retryTimer = Timer.periodic(Duration(seconds: 15), (_) async {
        final messages = await PendingMessageDbHelper.getPendingMessages();
        for (var msg in messages) {
          bool res = await _sendOverTor(msg['id'], msg['message'], msg['type'], replyToId: msg['replyTo']);
          if (res) {
            await PendingMessageDbHelper.removeMessage(msg['id']);
          } else {
            // Skip
            //
            //print("DEBUG: Send retry failed for message ID: ${msg['id']}.");
          }
        }
      });
  }

  Future<List<Message>> decryptMessagesBackground(
    List<Map<String, dynamic>> rawMessages,
    KeyManager keyManager,
  ) async {
    // `KeyManager` Cannot be passed directly to compute as it's not serializable
    // So decrypt inside main insolate but outside SetState or split decryption per message.
    // Alternatively, decrypt texts asynchronously one by one here or avoid compute.

    // For now, decrypt outside setState before calling setState.
    List<Message> messages = [];
    for (final msg in rawMessages) {
      if (_messageCache.containsKey(msg['id'])) {
        messages.add(_messageCache[msg['id']]!);
        continue;
      }
      try {
        
        if (msg['type'] == 'text') {
          messages.add(TextMessage(
            authorId: User(id: msg['senderId']).id,
            createdAt: DateTime.fromMillisecondsSinceEpoch(msg['timestamp']),
            id: msg['id'],
            replyToMessageId: msg['replyTo'],
            text: keyManager.decryptMessage(msg['message']),
          ));
        } else if (msg['type'] == 'file' || msg['type'] == "image") {
          final hybrid = jsonDecode(msg['message']);
          final rsaEncryptedAesKey = hybrid["aes_key"];
          final iv = e.IV.fromBase64(hybrid["iv"]);
          final encryptedData = base64Decode(hybrid["data"]);

          final aesKeyBytes = keyManager.decryptMyMessageBytes(rsaEncryptedAesKey);
          final aesKey = e.Key(Uint8List.fromList(aesKeyBytes));

          final decryptedBytes = AESHelper.decryptBytes(encryptedData, aesKey, iv);
          final base64Data = base64Encode(decryptedBytes);
          if (msg['type'] == "file") {
            messages.add(FileMessage(
              id: msg['id'],
              authorId: User(id: msg['senderId']).id,
              createdAt: DateTime.fromMillisecondsSinceEpoch(msg['timestamp']),
              replyToMessageId: msg['replyTo'],
              name: msg['fileName'] ?? "Unknown",
              size: msg['fileSize'] ?? decryptedBytes.length,
              source: "data:;base64,$base64Data",
            ));
          } else if (msg['type'] == "image") {
            messages.add(ImageMessage(
              id: msg['id'],
              authorId: User(id: msg['senderId']).id,
              createdAt: DateTime.fromMillisecondsSinceEpoch(msg['timestamp']),
              replyToMessageId: msg['replyTo'],
              size: msg['fileSize'] ?? decryptedBytes.length,
              source: "data:;base64,$base64Data",
            ));
          }
        }
      } catch (e) {
        messages.add(TextMessage(
          authorId: User(id: msg['senderId']).id,
          createdAt: DateTime.fromMillisecondsSinceEpoch(msg['timestamp']),
          id: msg['id'],
          replyToMessageId: msg['replyTo'],
          text: '🔒 Unable to decrypt message',
        ));
      }
    }
    //print("$messages");
    return messages;
  }

  String decodeBase58ToOnion(String base58String) {
    final bytes = base58.decode(base58String);
    final onion = utf8.decode(bytes);
    return '$onion.onion';
  }

  Future<String?> _getPeerPublicKeyPemFromDb(String peerId) async {
    final users = await DBHelper.getUsers(); // Or a specialized query for one user
    try {
      final user = users.firstWhere((u) => u['id'] == peerId);
      return user['publicKeyPem'] as String?;
    } catch (e) {
      return null; // Not found
    }
  }

  Future<bool> _fetchPeerPublicKey() async {
    if (widget.peerPublicKeyPem != null) {
      _peerPublicKey =
          widget.keyManager.importPeerPublicKey(widget.peerPublicKeyPem!);
      return true;
    }

    final cachedPem = await _getPeerPublicKeyPemFromDb(widget.peerId);
    if (cachedPem != null && cachedPem.isNotEmpty) {
      _peerPublicKey = widget.keyManager.importPeerPublicKey(cachedPem);
      return true;
    }

    final torClient = TorHttpClient(proxyHost: '127.0.0.1', proxyPort: 9050);

    try {
      final peerOnion = widget.peerId;
      final uri = Uri.parse("http://$peerOnion:12345/public");
      final response = await torClient.get(uri, {});
      final publicKeyPem = await response.transform(utf8.decoder).join();

      setState(() {
        _peerPublicKey =
            widget.keyManager.importPeerPublicKey(publicKeyPem);
      });
    } catch (e) {
      return false;
      //print("Failed to fetch peer public key: $e");
    } finally {
      torClient.close();
    }
    return true;
  }

  Future<void> _loadInitialMessages() async {
    () async {
      setState(() {
        _messages = InMemoryChatController();  
      });
    };
    await _loadMoreMessages();
  }

  Future<void> _loadMoreMessages() async {
    if (_loading || !_hasMore) return;
    _loading = true;

    final batch = await MessageDbHelper.getMessagesBetweenBatchWithId(
      widget.userId,
      widget.peerId,
      limit: 20,
      beforeTimestamp: _oldestTimestamp,
      beforeId: _oldestMessageId,
    );

    /* //print("old_TIME $_oldestTimestamp");
    //print("new_TIME $_newestTimestamp");
    //print("loading: $_loading");
    //print("hasmore: $_hasMore");*/
    //print("${batch.length}"); 
    ////print("$batch"); 
    if (!mounted) return;

    if (batch.length < 20) {
      //print("hasMore = false");
      _hasMore = false;
      _loading = false;
      if (batch.isEmpty) {
        return;
      }
    }

    final modifiableList = List.of(batch);
    modifiableList.sort((a, b) => (a['timestamp'] as int).compareTo(b['timestamp'] as int));

    final newMessages = await decryptMessagesBackground(modifiableList, widget.keyManager);
    
    //print("Loaded ${newMessages.length} more messages.");
    setState(() {
      _messages.insertAllMessages(newMessages, index: 0);
      _oldestTimestamp = batch.last['timestamp'];
      _oldestMessageId = batch.last['id']; // track last loaded message id
      _loading = false;
    });
  }

  void _startPolling() {
    Future.doWhile(() async {
      await Future.delayed(const Duration(seconds: 2));

      _loadNewMessages();
      return true;
    });
  }

  Future<void> _loadNewMessages() async {
    final batch = await MessageDbHelper.getMessagesBetweenBatch(
      widget.userId, widget.peerId,
      limit: 20,
      beforeTimestamp: null,
    );
    final newMessagesRaw = batch.where((msg) => _newestTimestamp == null || msg['timestamp'] > _newestTimestamp).toList();

    if (newMessagesRaw.isEmpty) return;

    final existingIds = _messages.messages.map((m) => m.id).toSet();
    final filteredRaw = newMessagesRaw.where((msg) => !existingIds.contains(msg['id'])).toList();

    if (filteredRaw.isEmpty) return;

    // Decrypt the filtered messages outside setState and main UI flow
    final decryptedMessages = await decryptMessagesBackground(filteredRaw, widget.keyManager);

    setState(() {
      // Insert all decrypted messages at once at the end of the list
      for (final msg in decryptedMessages) {
        _messages.insertMessage(msg, index: _messages.messages.length);
      }
    });

    _newestTimestamp = newMessagesRaw.first['timestamp'];
  }



  void _handleSendText(String text) async {

    if (!mounted) return;

    if (_peerPublicKey == null) {
    
      bool k = await _fetchPeerPublicKey();
      
      if (!mounted) return;

      if (k) {
        _loadInitialMessages();
        _startPolling();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Couldn\'t send message: Peer public key not available.'),
            duration: Duration(seconds: 3),
          ),
        );
        return;
      }
    }

    var replyToId = _replyToMessage?.id;

    final encryptedForPeer =
        widget.keyManager.encryptForPeer(text, _peerPublicKey!);
    final encryptedForSelf =
        widget.keyManager.encryptForSelf(text);

    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final messageId = Uuid().v4();

    //print("Sending message ID: $messageId, replyTo: {$replyToId}");
    // Store in DB
    await MessageDbHelper.insertMessage({
      'id': messageId,
      'senderId': widget.userId,
      'receiverId': widget.peerId,
      'message': encryptedForSelf,
      'type': 'text',
      'timestamp': timestamp,
      'replyTo': replyToId,
    });

    // Show decrypted instantly
    setState(() {
      _messages.insertMessage( 
        TextMessage(
          authorId: _user.id,
          createdAt: DateTime.fromMillisecondsSinceEpoch(timestamp),
          id: messageId,
          text: text,
          replyToMessageId: replyToId,
        ),
        index: _messages.messages.length,
      );
      _replyToMessage = null;
    });

    // Send encrypted to peer
    bool res = await _sendOverTor(messageId, encryptedForPeer, "text", replyToId: replyToId);
    if (res == false) {
      await PendingMessageDbHelper.insertPendingMessage({
        'id': messageId,
        'senderId': widget.userId,
        'receiverId': widget.peerId,
        'message': encryptedForPeer,
        'type': 'text',
        'timestamp': timestamp,
        'replyTo': replyToId,
      });
    }

  }

  Future<void> _handleSendImage() async {
    final picker = ImagePicker();
    final pickedFile = await picker.pickImage(source: ImageSource.gallery, requestFullMetadata: true);
    if (pickedFile == null) return;

    final bytes = await pickedFile.readAsBytes();
    _sendFile(bytes, pickedFile.name, "image");
  }

  Future<void> _handleSendFile() async {
    final result = await FilePicker.platform.pickFiles(withData: true);
    if (result == null || result.files.isEmpty) return;

    final file = result.files.first;

    _sendFile(file.bytes!, file.name, "file");
  }

  Future<void> _sendFile(Uint8List bytes, String fileName, String type) async {

    if (_peerPublicKey == null) {
    
      bool k = await _fetchPeerPublicKey();

      if (k) {
        _loadInitialMessages();
        _startPolling();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Couldn\'t send message: Peer public key not available.'),
            duration: Duration(seconds: 3),
          ),
        );
        return;
      }
    }


    var replyToId = _replyToMessage?.id;
    // Generate AES key + iv
    final aesKey = AESHelper.generateAESKey();
    final iv = AESHelper.generateIV();

    // Encrypt file with AES
    final aesEncryptedBytes = AESHelper.encryptBytes(bytes, aesKey, iv);

    // Encrypt AES key with peer's RSA key
    final rsaEncryptedAesKey = RSAHelper.encryptBytesWithPublicKey(aesKey.bytes, _peerPublicKey!);
    
    final payload = jsonEncode({
      "aes_key": rsaEncryptedAesKey,
      "iv": iv.base64,
      "data": base64Encode(aesEncryptedBytes)
    });

    final selfEncryptedKey = RSAHelper.encryptBytesWithPublicKey(aesKey.bytes, widget.keyManager.publicKey);
    final selfPayload = jsonEncode({
      "aes_key": selfEncryptedKey,
      "iv": iv.base64,
      "data": base64Encode(aesEncryptedBytes),
    });

    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final messageId = Uuid().v4();

    // Store locally
    await MessageDbHelper.insertMessage({
      'id': messageId,
      'senderId': widget.userId,
      'receiverId': widget.peerId,
      'message': selfPayload,
      'type': type,
      'fileName': fileName,
      'fileSize': bytes.length,
      'timestamp': timestamp,
      'replyTo': replyToId,
    });

    // Show immediately in chat
    setState(() {
      if (type == "file") {
        _messages.insertMessage(
          FileMessage(
            authorId: _user.id,
            createdAt: DateTime.fromMillisecondsSinceEpoch(timestamp),
            id: messageId,
            name: fileName,
            size: bytes.length,
            replyToMessageId: replyToId,
            source: "data:;base64,${base64Encode(bytes)}",
          ),
          index: _messages.messages.length,
        );
      } else if (type == "image") {
        _messages.insertMessage(
          ImageMessage(
            authorId: _user.id,
            createdAt: DateTime.fromMillisecondsSinceEpoch(timestamp),
            id: messageId,
            size: bytes.length,
            replyToMessageId: replyToId,
            source: "data:;base64,${base64Encode(bytes)}",
          ),
          index: _messages.messages.length,
        );
      }
    });

    final success = await _sendOverTor(messageId, payload, type, fileName: fileName, fileSize: bytes.length);
    
    if (!success) {
      await PendingMessageDbHelper.insertPendingMessage({
        "id": messageId,
        "senderId": widget.userId,
        "receiverId": widget.peerId,
        "message": payload,
        "type": type,
        "fileName": fileName,
        "fileSize": bytes.length,
        "timestamp": timestamp,
        'replyTo': replyToId,
      });
    }
  }

  Future<bool> _sendOverTor(
    String id,
    String encrypted,
    String type, {
    String? replyToId,
    String? fileName,
    int? fileSize,
  }) async {
    final torClient = TorHttpClient(proxyHost: '127.0.0.1', proxyPort: 9050);

    try {
      final peerOnion = widget.peerId;
      final uri = Uri.parse("http://$peerOnion:12345/message");
      final headers = {'Content-Type': 'application/json'};
      final body = jsonEncode({
        "id": id,
        "senderId": widget.userId,
        "receiverId": widget.peerId,
        "message": encrypted,
        "type": type,
        "fileName": fileName,
        "fileSize": fileSize,
        "replyTo": replyToId,
        "timestamp": DateTime.now().millisecondsSinceEpoch,
      });
      final response = await torClient.post(uri, headers, body);
      final responseText = await response.transform(utf8.decoder).join();
      // print("Message sent: $responseText");

      return true;
    } 
    catch (e) {
      //print("Failed to send message: $e");
      return false;
    } 
    finally {
      torClient.close();
    }
  }



  void _handleSend(dynamic message) {
    if (message is TextMessage && message.text.isNotEmpty) {
      _handleSendText(message.text);
    } else if (message is String && message.isNotEmpty) {
      _handleSendText(message);
    }
  }

  void _openChatProfile() async {
    final peerContact = Contact(
      id: widget.peerId,
      name: _peerName, // Use local copy
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
            // Update in database
            await DBHelper.insertOrUpdateUser({
              'id': updatedContact.id,
              'name': updatedContact.name,
              'avatarUrl': updatedContact.avatarUrl,
              'publicKeyPem': updatedContact.publicKeyPem,
            });
            widget.reloadUsers();
          },
          onDeleteChat: () async {
            // Delete all messages between these users
            await MessageDbHelper.deleteMessagesBetween(
              widget.userId,
              widget.peerId,
            );
            // Refresh the message list
            resetChatState();
            setState(() {
              _messages = InMemoryChatController();
              _chatKey = UniqueKey();
            });
            _loadInitialMessages();
          },
          onDeleteContact: () async {
            // Delete contact from database
            await DBHelper.deleteUser(widget.peerId);
            // Close chat screen
            resetChatState();

            setState(() {
              _messages = InMemoryChatController();
              _chatKey = UniqueKey();
              _replyToMessage = null;

              // Instead of Navigator.pop(), just clear selectedContact to unmount ChatScreen 
            });
            
            widget.clearChat();
          },
        ),
      ),
    );

    // If a contact was updated, refresh the UI
    if (result != null && result is Contact) {
      setState(() {
        _peerName = result.name; // Update local copy
      });
    }
  }

  Color invertColor(Color color) {
    return Color.fromARGB(
      (color.a *255.0).round(),
      255 - (color.r *255.0).round(),
      255 - (color.g *255.0).round(),
      255 - (color.b *255.0).round(),
    );
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
      color: Theme.of(context).brightness == Brightness.dark ? Theme.of(context).colorScheme.secondary : Theme.of(context).colorScheme.primary,
      padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              previewText,
              style: TextStyle(color: Theme.of(context).brightness == Brightness.dark ? Colors.black : Colors.white, fontStyle: FontStyle.italic),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            icon: Icon(Icons.close),
            color: Theme.of(context).brightness == Brightness.dark ? Colors.black : Colors.white,
            onPressed: () {
              setState(() {
                _replyToMessage = null;
              });
            },
          ),
        ],
      ),
    );
  }



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
                          backgroundColor: Theme.of(context).primaryColor.withValues(alpha: 0.1),
                          child: Text(
                            _peerName.isNotEmpty ? _peerName[0].toUpperCase() : 'U',
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
                backgroundColor: Theme.of(context).primaryColor.withValues(alpha: 0.8),
                child: Text(
                  _peerName.isNotEmpty ? _peerName[0].toUpperCase() : 'U',
                  style: TextStyle(
                    color: Theme.of(context).brightness == Brightness.dark ? Theme.of(context).hintColor : Colors.white,
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
                      color: Theme.of(context).brightness == Brightness.dark ? Theme.of(context).hintColor : Theme.of(context).primaryColor,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        actions: [
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
            // 🟨 Show reply preview (if replying to a message)
            if (_replyToMessage != null)
              _buildReplyPreview(),

            // 🟩 Chat messages — takes up remaining space
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
                onMessageLongPress: (context, message, {LongPressStartDetails? details, int? index}) {
                  setState(() {
                    _replyToMessage = message;
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
                    final msgDate = DateTime.fromMillisecondsSinceEpoch(message.createdAt!.millisecondsSinceEpoch);
                    final currentDay = DateTime(msgDate.year, msgDate.month, msgDate.day);

                    DateTime? prevDay;
                    if (index > 0) {
                      final prevMsg = _messages.messages[index - 1];
                      final prevDate = DateTime.fromMillisecondsSinceEpoch(prevMsg.createdAt!.millisecondsSinceEpoch);
                      prevDay = DateTime(prevDate.year, prevDate.month, prevDate.day);
                    }

                    bool showDateHeader = index == 0 || prevDay == null || !currentDay.isAtSameMomentAs(prevDay);

                    Widget replyPreviewWidget = const SizedBox.shrink();
                    final replyId = message.replyToMessageId;
                    if (replyId != null) {
                      Message? repliedMessage;
                      try {
                        repliedMessage = _messages.messages.firstWhere((m) => m.id == replyId);
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
                          constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.7),
                          child: Text(
                            previewText,
                            style: const TextStyle(
                              fontStyle: FontStyle.italic,
                              color: Colors.black54,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: isSentByMe ? TextAlign.right : TextAlign.left,
                          ),
                        );
                      }
                    }

                    return Column(
                      children: [
                        if (showDateHeader)
                          Container(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            alignment: Alignment.center,
                            child: Text(
                              "${msgDate.day}/${msgDate.month}/${msgDate.year}",
                              style: const TextStyle(fontSize: 12, color: Colors.grey),
                            ),
                          ),
                        GestureDetector(
                          behavior: HitTestBehavior.translucent,
                          onHorizontalDragUpdate: (details) {
                            setState(() {
                              double delta = details.delta.dx;
                              if (isSentByMe) delta = -delta;
                              _dragOffsets[message.id] = (_dragOffsets[message.id] ?? 0) + delta;
                              if (_dragOffsets[message.id]! < 0) _dragOffsets[message.id] = 0;
                              if (_dragOffsets[message.id]! > 100) _dragOffsets[message.id] = 100;
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
                            offset: Offset(isSentByMe ? -(_dragOffsets[message.id] ?? 0) : (_dragOffsets[message.id] ?? 0), 0),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                              child: SizeTransition(
                                sizeFactor: animation,
                                child: Row(
                                  mainAxisAlignment: isSentByMe ? MainAxisAlignment.end : MainAxisAlignment.start,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Flexible(
                                      child: Column(
                                        crossAxisAlignment: isSentByMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
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
                      ],
                    );
                  },
                  fileMessageBuilder: fileMessageBuilder,
                  imageMessageBuilder: myImageMessageBuilder,

                  composerBuilder: (context) {
                    return (
                      Padding(padding: EdgeInsetsGeometry.all(0))
                    );
                  }
                ),
              ),
            ),

            // 🟦 Composer is fixed to bottom
            _buildComposer(context),
          ],
        ),
      ),
    );
  }

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

    final msgDate = DateTime.fromMillisecondsSinceEpoch(message.createdAt!.millisecondsSinceEpoch);
    final timeString =
        "${msgDate.hour.toString().padLeft(2, '0')}:${msgDate.minute.toString().padLeft(2, '0')}";

    return Column(
      crossAxisAlignment: isSentByMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        GestureDetector(
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => Scaffold(
                  backgroundColor: Theme.of(context).brightness == Brightness.dark ? Colors.black : Colors.white,
                  appBar: AppBar(
                    backgroundColor: Colors.transparent,
                    elevation: 0,
                  ),
                  body: Center(
                    child: InteractiveViewer(
                      child: Image.memory(bytes),
                    ),
                  ),
                ),
              ),
            );
          },
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.memory(
              width: max(200, (message.width?? 20) / 4),
              height: max(200, (message.height ?? 20 )/ 4),
              bytes,
              fit: BoxFit.cover,
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          timeString,
          style: TextStyle(fontSize: 10, color: Colors.grey[600]),
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

    Future<void> downloadBase64File() async {
      try {
        final base64Str = message.source.contains('base64,')
            ? message.source.split('base64,')[1]
            : message.source;

        Uint8List bytes = base64Decode(base64Str);

        final dir = await getDownloadsDirectory();
        File file = File('${dir!.path}/${message.name}');
        int c = 0;
        while (await file.exists()) {
          file = File('${dir.path}/${message.name} - $c');
          c += 1;
        }
        await file.writeAsBytes(bytes);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Successfully downloaded ${file.path.split("/").last}')),
        );
      } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error downloading file: $e')),
        );
      }
    }

    final msgDate = DateTime.fromMillisecondsSinceEpoch(message.createdAt!.millisecondsSinceEpoch);
    final timeString = "${msgDate.hour.toString().padLeft(2,'0')}:${msgDate.minute.toString().padLeft(2,'0')}";

    // Calculate file size in KB / MB
    String fileSizeString = '';
    if (message.size != null) {
      final sizeInKB = message.size! / 1024;
      if (sizeInKB < 1024) {
        fileSizeString = "${sizeInKB.toStringAsFixed(1)} KB";
      } else {
        fileSizeString = "${(sizeInKB / 1024).toStringAsFixed(1)} MB";
      }
    }

    return Column(
      crossAxisAlignment: isSentByMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
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
                  CircleAvatar(
                    backgroundColor: Theme.of(context).primaryColor.withAlpha(120),
                    child: Icon(Icons.insert_drive_file, size: 24, color: Theme.of(context).brightness == Brightness.dark ? Colors.grey[300] : Colors.white),
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          message.name,
                          style: TextStyle(color: Theme.of(context).brightness == Brightness.dark ? Colors.black : Colors.white),
                          overflow: TextOverflow.visible,
                        ),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            if (fileSizeString.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(right: 4),
                                child: Text(
                                  fileSizeString,
                                  style: TextStyle(fontSize: 10, color: Theme.of(context).brightness == Brightness.dark ? Colors.grey[900] : Colors.white),
                                ),
                              ),
                            Text(
                              timeString,
                              style: TextStyle(fontSize: 10, color: Theme.of(context).brightness == Brightness.dark ? Colors.grey[900] : Colors.white),
                            ),
                          ],
                        )
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

  Widget _buildComposer(BuildContext context) {
    final theme = Theme.of(context);
    final textController = TextEditingController();
    String currentText = '';

    return StatefulBuilder(
      builder: (context, setState) {
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          color: theme.scaffoldBackgroundColor,
          child: Row(
            children: [
              // + button with popup for file/image
              PopupMenuButton<String>(
                icon: Icon(Icons.drive_folder_upload, color: theme.iconTheme.color),
                onSelected: (value) {
                  if (value == "image") _handleSendImage();
                  if (value == "file") _handleSendFile();
                },
                itemBuilder: (context) => [
                  const PopupMenuItem(
                    value: 'image',
                    child: Row(
                      children: [
                        Icon(Icons.image),
                        SizedBox(width: 8),
                        Text("Upload Image"),
                      ],
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'file',
                    child: Row(
                      children: [
                        Icon(Icons.attach_file),
                        SizedBox(width: 8),
                        Text("Upload File"),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 8),

              // Text input field
              Expanded(
                child: TextField(
                  controller: textController,
                  onChanged: (text) => setState(() => currentText = text),
                  onSubmitted: (text) {
                    if (text.trim().isNotEmpty) {
                      _handleSendText(text.trim());
                      textController.clear();
                      setState(() => currentText = '');
                    }
                  },
                  decoration: InputDecoration(
                    hintText: 'Type a message',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(20),
                    ),
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  ),
                  minLines: 1,
                  maxLines: 5,
                ),
              ),
              const SizedBox(width: 8),

              // Send button
              IconButton(
                icon: Icon(
                  Icons.send,
                  color: currentText.trim().isEmpty
                      ? Colors.grey
                      : theme.iconTheme.color,
                ),
                onPressed: currentText.trim().isEmpty
                    ? null
                    : () {
                        _handleSendText(currentText.trim());
                        textController.clear();
                        setState(() => currentText = '');
                      },
              ),
            ],
          ),
        );
      },
    );
  }

}