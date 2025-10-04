import 'dart:convert';

import 'package:bs58/bs58.dart';
import 'package:flutter/material.dart';
import 'package:flutter_chat_ui/flutter_chat_ui.dart';
import 'package:flutter_chat_types/flutter_chat_types.dart' as types;
import 'package:http/http.dart' as http;
import 'package:pointycastle/asymmetric/api.dart';
import 'package:prysm/util/message_db_helper.dart';
import 'package:prysm/util/tor_service.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/message_http_client.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'dart:typed_data';


class ChatScreen extends StatefulWidget {
  final String userId;
  final String userName;
  final String peerId;
  final String peerName;
  final TorManager torManager;
  final KeyManager keyManager;
  final String? peerPublicKeyPem;

  const ChatScreen({
    required this.userId,
    required this.userName,
    required this.peerId,
    required this.peerName,
    required this.torManager,
    required this.keyManager,
    this.peerPublicKeyPem,
    Key? key,
  }) : super(key: key);

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final List<types.Message> _messages = [];
  late final types.User _user;
  RSAPublicKey? _peerPublicKey;

  @override
  void initState() {
    super.initState();
    _user = types.User(id: widget.userId);
    _fetchPeerPublicKey().then((_) {
      _loadMessages();
      _startPolling();
    });
  }

  String decodeBase58ToOnion(String base58String) {
    final bytes = base58.decode(base58String);
    final onion = utf8.decode(bytes);
    return '$onion.onion';
  }

  Future<void> _fetchPeerPublicKey() async {
    if (widget.peerPublicKeyPem != null) {
      _peerPublicKey =
          widget.keyManager.importPeerPublicKey(widget.peerPublicKeyPem!);
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

  void _loadMessages() async {
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
  }


  void _startPolling() {
    Future.doWhile(() async {
      await Future.delayed(const Duration(seconds: 2));
      _loadMessages();
      return true;
    });
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
      _messages.insert(
        0,
        types.TextMessage(
          author: _user,
          createdAt: timestamp,
          id: messageId,
          text: text,
        ),
      );
    });

    // Send encrypted to peer
    await _sendOverTor(messageId, encryptedForPeer, "text");
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

  Future<void> _sendOverTor(
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
    } catch (e) {
      print("Failed to send message: $e");
    } finally {
      torClient.close();
    }
  }



  void _handleSend(types.PartialText message) {
    if (message.text.isNotEmpty) {
      _handleSendText(message.text);
    }
  }


  @override
Widget build(BuildContext context) {
  return Scaffold(
    appBar: AppBar(
      title: Text(widget.peerName),
      /*
      actions: [
        IconButton(
          icon: Icon(Icons.image),
          onPressed: _handleSendImage,
        ),
        IconButton(
          icon: Icon(Icons.attach_file),
          onPressed: _handleSendFile,
        ),
      ],*/
    ),
    body: Chat(
      theme: const DefaultChatTheme(
        backgroundColor: Colors.white,
        primaryColor: Colors.teal,
        inputBackgroundColor: Colors.grey,
        sentMessageBodyTextStyle: TextStyle(color: Colors.white),
      ),
      messages: _messages,
      user: _user,
      onSendPressed: _handleSend,
    ),
  );
}

}
