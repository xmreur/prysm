import 'dart:async';
import 'dart:convert';

import 'package:bs58/bs58.dart';
import 'package:flutter/material.dart';
import 'package:flutter_chat_ui/flutter_chat_ui.dart';
import 'package:flutter_chat_types/flutter_chat_types.dart' as types;
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
  final List<types.Message> _messages = [];
  final Map<String, types.Message> _messageCache = {};
  late final types.User _user;
  bool _loading = false;
  bool _hasMore = true;
  int? _oldestTimestamp;
  String? _oldestMessageId;
  int? _newestTimestamp;

  RSAPublicKey? _peerPublicKey;

  String _peerName = '';
  int _currentTheme = 0;
  int _lastMessageCount = 0;

  final AutoScrollController _scrollController = AutoScrollController();
  Timer? _debounceTimer;
  Timer? _retryTimer;

  void _scrollListener() {
    if (_scrollController.position.pixels >= (_scrollController.position.maxScrollExtent - 50) && !_loading && _hasMore) {
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
    _user = types.User(id: widget.userId);
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
    _messages.clear();
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
      _resetChatState();
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
          bool res = await _sendOverTor(msg['id'], msg['message'], msg['type']);
          if (res) {
            await PendingMessageDbHelper.removeMessage(msg['id']);
          } else {
            // Skip
            print("DEBUG: Send retry failed for message ID: ${msg['id']}.");
          }
        }
      });
  }

  Future<List<types.Message>> decryptMessagesBackground(
    List<Map<String, dynamic>> rawMessages,
    KeyManager keyManager,
  ) async {
    // `KeyManager` Cannot be passed directly to compute as it's not serializable
    // So decrypt inside main insolate but outside SetState or split decryption per message.
    // Alternatively, decrypt texts asynchronously one by one here or avoid compute.

    // For now, decrypt outside setState before calling setState.
    List<types.Message> messages = [];
    for (final msg in rawMessages) {
      if (_messageCache.containsKey(msg['id'])) {
        messages.add(_messageCache[msg['id']]!);
        continue;
      }
      try {
        if (msg['type'] == 'text') {
          messages.add(types.TextMessage(
            author: types.User(id: msg['senderId']),
            createdAt: msg['timestamp'],
            id: msg['id'],
            text: keyManager.decryptMessage(msg['message']),
          ));
        } else if (msg['type'] == 'file') {
          final decryptedBytes = keyManager.decryptMyMessageBytes(msg['message']);
          final base64Data = base64Encode(decryptedBytes);
          messages.add(types.FileMessage(
            author: types.User(id: msg['senderId']),
            createdAt: msg['timestamp'],
            id: msg['id'],
            name: msg['fileName'] ?? "unknown",
            size: msg['fileSize'] ?? decryptedBytes.length,
            uri: "data:;base64,$base64Data",
          ));
        }
      } catch (e) {
        messages.add(types.TextMessage(
          author: types.User(id: msg['senderId']),
          createdAt: msg['timestamp'],
          id: msg['id'],
          text: '🔒 Unable to decrypt message',
        ));
      }
    }
    return messages.reversed.toList();
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

    final newMessages = await decryptMessagesBackground(batch, widget.keyManager);

    setState(() {
      _messages.addAll(newMessages);
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
              return types.TextMessage(
                author: types.User(id: msg['senderId']),
                createdAt: msg['timestamp'],
                id: msg['id'],
                text: widget.keyManager.decryptMyMessage(msg['message']),
              );
            } else if (msg['type'] == "image" || msg['type'] == "file") {
              final decryptedBytes = widget.keyManager.decryptMyMessageBytes(msg['message']);
              final base64Data = base64Encode(decryptedBytes);

              print(msg);
              return types.FileMessage(
                author: types.User(id: msg['senderId']),
                createdAt: msg['timestamp'],
                id: msg['id'],
                name: msg['fileName'] ?? "unknown",
                size: msg['fileSize'] ?? decryptedBytes.length,
                uri: "data:;base64,$base64Data",
              );
            }
          } catch (e) {
            return types.TextMessage(
              author: types.User(id: msg['senderId']),
              createdAt: msg['timestamp'],
              id: msg['id'],
              text: "🔒 Unable to decrypt message",
            );
          }
          return types.TextMessage(
            author: types.User(id: msg['senderId']),
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

    final existingId = _messages.map((m) => m.id).toSet();

    for (final rawMsg in newMessagesRaw) {
      if (existingId.contains(rawMsg['id'])) continue;

      try {
        final decryptedMsg = await Future(() {
          if (rawMsg['type'] == 'text') {
            return types.TextMessage(
              author: types.User(id: rawMsg['senderId']),
              createdAt: rawMsg['timestamp'],
              id: rawMsg['id'],
              text: widget.keyManager.decryptMessage(rawMsg['message']),
            );
          } else {
            final decryptedBytes = widget.keyManager.decryptMyMessageBytes(rawMsg['message']);
            final base64Data = base64Encode(decryptedBytes);
            return types.FileMessage(
              author: types.User(id: rawMsg['senderId']),
              createdAt: rawMsg['timestamp'],
              id: rawMsg['id'],
              name: rawMsg['fileName'] ?? "unknown",
              size: rawMsg['fileSize'] ?? decryptedBytes.length,
              uri: "data:;base64,$base64Data",
            );
          }
        });

        setState(() {
          _messages.add(decryptedMsg);
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
      print("Peer public key not ready yet.");
      return;
    }

    final encryptedForPeer =
        widget.keyManager.encryptForPeer(text, _peerPublicKey!);
    final encryptedForSelf =
        widget.keyManager.encryptForSelf(text);

    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final messageId = timestamp.toString();

    // Store in DB
    await MessageDbHelper.insertMessage({
      'id': messageId,
      'senderId': widget.userId,
      'receiverId': widget.peerId,
      'message': encryptedForSelf,
      'type': 'text',
      'timestamp': timestamp,
    });

    // Show decrypted instantly
    setState(() {
      _messages.add(
        types.TextMessage(
          author: _user,
          createdAt: timestamp,
          id: messageId,
          text: text,
        ),
      );
    });

    // Send encrypted to peer
    bool res = await _sendOverTor(messageId, encryptedForPeer, "text");
    if (res == false) {
      await PendingMessageDbHelper.insertPendingMessage({
        'id': messageId,
        'senderId': widget.userId,
        'receiverId': widget.peerId,
        'message': encryptedForSelf,
        'type': 'text',
        'timestamp': timestamp,
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
      _messages.insert(
        0,
        types.FileMessage(
          author: _user,
          createdAt: timestamp,
          id: messageId,
          name: fileName,
          size: bytes.length,
          uri: "data:;base64,$encryptedForSelf",
        ),
      );
    });

    await _sendOverTor(messageId, encryptedForPeer, type);
  }

  Future<bool> _sendOverTor(
    String id,
    String encrypted,
    String type, {
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



  void _handleSend(types.PartialText message) {
    if (message.text.isNotEmpty) {
      _handleSendText(message.text);
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
            _messages.clear();
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
      body: Chat(
        theme: DefaultChatTheme(
          backgroundColor: Colors.transparent,
          primaryColor: Theme.of(context).colorScheme.primary.withValues(alpha: 1.0).withAlpha(170),
          inputBackgroundColor: Colors.grey,
          sentMessageBodyTextStyle: TextStyle(color: Colors.white),
        ),
        messages: _messages.reversed.toList(),
        user: _user,
        onSendPressed: _handleSend,
        scrollController: _scrollController,
      ),
    );
  }


}
