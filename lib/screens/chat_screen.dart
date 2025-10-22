import 'dart:async';
import 'dart:convert';

import 'package:bs58/bs58.dart';
import 'package:flutter/material.dart';
import 'package:flutter_chat_ui/flutter_chat_ui.dart';
import 'package:flutter_chat_core/flutter_chat_core.dart';
// import 'package:http/http.dart' as http;
import 'package:pointycastle/asymmetric/api.dart';
import 'package:prysm/screens/chat_profile_screen.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/util/message_db_helper.dart';
import 'package:prysm/util/pending_message_db_helper.dart';
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

  const ChatScreen({
    required this.userId,
    required this.userName,
    required this.peerId,
    required this.peerName,
    required this.torManager,
    required this.keyManager,
    this.peerPublicKeyPem,
    this.currentTheme = 0,
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

  
  void _resetChatState() {
    _messages = InMemoryChatController();
    _replyToMessage = null;
    _messageCache.clear();
    _oldestTimestamp = null;
    _oldestMessageId = null;
    _newestTimestamp = null;
    _hasMore = true;
    _loading = false;
  }

  @override
  void didUpdateWidget(covariant ChatScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.peerId != widget.peerId) {
      print("CHANGED");
      setState(() {
        _resetChatState();
      });
      _fetchPeerPublicKey().then((_) {
        _loadInitialMessages();
      });
    }
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
            print("DEBUG: Send retry failed for message ID: ${msg['id']}.");
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
        } else if (msg['type'] == 'file') {
          final decryptedBytes = keyManager.decryptMyMessageBytes(msg['message']);
          final base64Data = base64Encode(decryptedBytes);
          messages.add(FileMessage(
            authorId: User(id: msg['senderId']).id,
            createdAt: DateTime.fromMillisecondsSinceEpoch(msg['timestamp']),
            id: msg['id'],
            replyToMessageId: msg['replyTo'],
            name: msg['fileName'] ?? "uaddnknown",
            size: msg['fileSize'] ?? decryptedBytes.length,
            source: "data:;base64,$base64Data",
          ));
        }
      } catch (e) {
        print(e);
        messages.add(TextMessage(
          authorId: User(id: msg['senderId']).id,
          createdAt: DateTime.fromMillisecondsSinceEpoch(msg['timestamp']),
          id: msg['id'],
          replyToMessageId: msg['replyTo'],
          text: '🔒 Unable to decrypt message',
        ));
      }
    }
    print("$messages");
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

  Future<void> _fetchPeerPublicKey() async {
    if (widget.peerPublicKeyPem != null) {
      _peerPublicKey =
          widget.keyManager.importPeerPublicKey(widget.peerPublicKeyPem!);
      return;
    }

    final cachedPem = await _getPeerPublicKeyPemFromDb(widget.peerId);
    if (cachedPem != null && cachedPem.isNotEmpty) {
      _peerPublicKey = widget.keyManager.importPeerPublicKey(cachedPem);
      return;
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
      print("Failed to fetch peer public key: $e");
    } finally {
      torClient.close();
    }
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

    /* print("old_TIME $_oldestTimestamp");
    print("new_TIME $_newestTimestamp");
    print("loading: $_loading");
    print("hasmore: $_hasMore");*/
    print("${batch.length}"); 
    //print("$batch"); 
    if (!mounted) return;

    if (batch.length < 20) {
      print("hasMore = false");
      _hasMore = false;
      _loading = false;
      if (batch.isEmpty) {
        return;
      }
    }

    final modifiableList = List.of(batch);
    modifiableList.sort((a, b) => (a['timestamp'] as int).compareTo(b['timestamp'] as int));

    final newMessages = await decryptMessagesBackground(modifiableList, widget.keyManager);
    
    print("Loaded ${newMessages.length} more messages.");
    setState(() {
      _messages.insertAllMessages(newMessages, index: 0);
      _oldestTimestamp = batch.last['timestamp'];
      _oldestMessageId = batch.last['id']; // track last loaded message id
      _loading = false;
    });
  }

  /*void _loadMessages() async {
  final loadedMessages =
    await MessageDbHelper.getMessagesBetween(widget.userId, widget.peerId);

    if (!mounted) return;

    setState(() {
      _messages.clear();
      _messages.addAll(
        loadedMessages.map((msg) {
          try {
            if (msg['type'] == "text") {
              return TextMessage(
                author: User(id: msg['senderId']),
                createdAt: msg['timestamp'],
                id: msg['id'],
                text: widget.keyManager.decryptMyMessage(msg['message']),
              );
            } else if (msg['type'] == "image" || msg['type'] == "file") {
              final decryptedBytes = widget.keyManager.decryptMyMessageBytes(msg['message']);
              final base64Data = base64Encode(decryptedBytes);

              print(msg);
              return FileMessage(
                author: User(id: msg['senderId']),
                createdAt: msg['timestamp'],
                id: msg['id'],
                name: msg['fileName'] ?? "unknown",
                size: msg['fileSize'] ?? decryptedBytes.length,
                uri: "data:;base64,$base64Data",
              );
            }
          } catch (e) {
            return TextMessage(
              author: User(id: msg['senderId']),
              createdAt: msg['timestamp'],
              id: msg['id'],
              text: "🔒 Unable to decrypt message",
            );
          }
          return TextMessage(
            author: User(id: msg['senderId']),
            createdAt: msg['timestamp'],
            id: msg['id'],
            text: "Unsupported message type",
          );
        }),
      );
    });
  }*/


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

    final existingId = _messages.messages.map((m) => m.id).toSet();

    for (final rawMsg in newMessagesRaw) {
      if (existingId.contains(rawMsg['id'])) continue;

      try {
        final decryptedMsg = await Future(() {
          if (rawMsg['type'] == 'text') {
            return TextMessage(
              authorId: User(id: rawMsg['senderId']).id,
              createdAt: DateTime.fromMillisecondsSinceEpoch(rawMsg['timestamp']),
              id: rawMsg['id'],
              text: widget.keyManager.decryptMessage(rawMsg['message']),
              replyToMessageId: rawMsg['replyTo']
            );
          } else {
            final decryptedBytes = widget.keyManager.decryptMyMessageBytes(rawMsg['message']);
            final base64Data = base64Encode(decryptedBytes);
            return FileMessage(
              authorId: User(id: rawMsg['senderId']).id,
              createdAt: DateTime.fromMillisecondsSinceEpoch(rawMsg['timestamp']),
              id: rawMsg['id'],
              name: rawMsg['fileName'] ?? "unknown",
              size: rawMsg['fileSize'] ?? decryptedBytes.length,
              source: "data:;base64,$base64Data",
              replyToMessageId: rawMsg['replyTo']
            );
          }
        });

        setState(() {
          _messages.insertMessage(decryptedMsg, index: _messages.messages.length);
        });
      } catch (_) {
        // Handle decrypt error if needed
      }
    }

    if (newMessagesRaw.isNotEmpty) {
      _newestTimestamp = newMessagesRaw.first['timestamp'];
    }
  }


  void _handleSendText(String text) async {

    if (_peerPublicKey == null) {
      _fetchPeerPublicKey().then((_) {
        _loadInitialMessages();
        _startPolling();
      });
      print("Peer public key not ready yet.");
      
      return;
    }

    var replyToId = _replyToMessage?.id;



    final encryptedForPeer =
        widget.keyManager.encryptForPeer(text, _peerPublicKey!);
    final encryptedForSelf =
        widget.keyManager.encryptForSelf(text);

    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final messageId = Uuid().v4();

    print("Sending message ID: $messageId, replyTo: {$replyToId}");
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
    if (_peerPublicKey == null) return;

    // Encrypt file for peer & self
    final encryptedForPeer = widget.keyManager.encryptBytesForPeer(bytes, _peerPublicKey!);
    final encryptedForSelf = widget.keyManager.encryptBytesForSelf(bytes);

    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final messageId = timestamp.toString();

    // Store locally
    await MessageDbHelper.insertMessage({
      'id': messageId,
      'senderId': widget.userId,
      'receiverId': widget.peerId,
      'message': encryptedForSelf,
      'type': type,
      'fileName': fileName,
      'fileSize': bytes.length,
      'timestamp': timestamp,
    });

    // Show immediately in chat
    setState(() {
      _messages.insertMessage(
        FileMessage(
          authorId: _user.id,
          createdAt: DateTime.fromMillisecondsSinceEpoch(timestamp),
          id: messageId,
          name: fileName,
          size: bytes.length,
          source: "data:;base64,$encryptedForSelf",
        ),
        index: _messages.messages.length,
      );
    });

    await _sendOverTor(messageId, encryptedForPeer, type);
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
      print("Message sent: $responseText");

      return true;
    } 
    catch (e) {
      print("Failed to send message: $e");
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
          },
          onDeleteChat: () async {
            // Delete all messages between these users
            await MessageDbHelper.deleteMessagesBetween(
              widget.userId,
              widget.peerId,
            );
            // Refresh the message list
            _messages.messages.clear();
            _loadInitialMessages();
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

    return Container(
      color: Theme.of(context).brightness == Brightness.dark ? Theme.of(context).colorScheme.secondary : Theme.of(context).colorScheme.primary,
      padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Replying to: ${(_replyToMessage as TextMessage).text}',
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
      body: Column(
        children: [
          if (_replyToMessage != null)
            _buildReplyPreview(),  // Your reply preview widget here
          
          Expanded(
            child: Chat(
              key: ValueKey(widget.peerId),
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
                chatAnimatedListBuilder: ( context, itemBuilder) {
                  return ChatAnimatedList(
                    itemBuilder: itemBuilder,
                    onEndReached: () async {
                      await _loadMoreMessages();
                    },
                    //shouldScrollToEndWhenAtBottom: false,
                    //scrollController: _scrollController,
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
                  // Current message date
                  final msgDate = DateTime.fromMillisecondsSinceEpoch(message.createdAt!.millisecondsSinceEpoch);
                  final currentDay = DateTime(msgDate.year, msgDate.month, msgDate.day);

                  DateTime? prevDay;
                  if (index > 0) {
                    final prevMsg = _messages.messages[index - 1];
                    final prevDate = DateTime.fromMillisecondsSinceEpoch(prevMsg.createdAt!.millisecondsSinceEpoch);
                    prevDay = DateTime(prevDate.year, prevDate.month, prevDate.day);
                  }

                  bool showDateHeader = index == 0 || prevDay == null || !currentDay.isAtSameMomentAs(prevDay);

                  // Build reply preview widget if replyToMessage exists
                  Widget replyPreviewWidget = SizedBox.shrink();
                  final replyId = message.replyToMessageId;
                  if (replyId != null) {
                    Message? repliedMessage;
                    try {
                      repliedMessage = _messages.messages.firstWhere((m) => m.id == replyId);
                    } catch (e) {
                      repliedMessage = null;
                    }

                    if (repliedMessage is TextMessage) {
                      replyPreviewWidget = Container(
                        padding: EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Colors.grey.shade200,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.7),
                        child: Text(
                          repliedMessage.text,
                          style: TextStyle(
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
                          padding: EdgeInsets.symmetric(vertical: 8),
                          alignment: Alignment.center,
                          child: Text(
                            "${msgDate.day}/${msgDate.month}/${msgDate.year}",
                            style: TextStyle(fontSize: 12, color: Colors.grey),
                          ),
                        ),
                      GestureDetector(
                        behavior: HitTestBehavior.translucent,
                        onLongPress: () {
                          // Add to selection, if only one show reactions
                        },
                        onHorizontalDragUpdate: (details) {
                          setState(() {
                            double delta = details.delta.dx;
                            if (isSentByMe) {
                              delta = -delta;
                            }
                            _dragOffsets[message.id] = (_dragOffsets[message.id] ?? 0) + delta;
                            // Clamp offset if needed, e.g. max 100 px right, min 0 (no left drag)
                            if (_dragOffsets[message.id]! < 0) _dragOffsets[message.id] = 0;
                            if (_dragOffsets[message.id]! > 100) _dragOffsets[message.id] = 100;
                          });
                        },
                        onHorizontalDragEnd: (details) {
                          setState(() {
                            // Trigger reply on sufficient drag distance
                            if ((_dragOffsets[message.id] ?? 0) > 50) {
                              _replyToMessage = message;
                            }
                            // Reset drag offset after gesture ends
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
                        )
                      ),
                    ],
                  );
                }
              ),
            )
          )
        ],
      )
    );
  }


}
