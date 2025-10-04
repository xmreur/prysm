import 'package:flutter/material.dart';
import 'package:flutter_chat_ui/flutter_chat_ui.dart';
import 'package:flutter_chat_types/flutter_chat_types.dart' as types;
import 'package:prysm/util/tor_service.dart';

class ChatScreen extends StatefulWidget {
  final String userId;
  final String userName;
  final String peerId;
  final String peerName;
  final TorManager torManager;

  const ChatScreen({
    required this.userId,
    required this.userName,
    required this.peerId,
    required this.peerName,
    required this.torManager,
    Key? key,
  }) : super(key: key);

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final List<types.Message> _messages = [];
  late final types.User _user;

  @override
  void initState() {
    super.initState();
    _user = types.User(id: widget.userId);
    // TODO: Initialize socket connections using widget.torManager and peerId here
  }

  void _handleSend(types.PartialText message) {
    final textMessage = types.TextMessage(
      author: _user,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      text: message.text,
    );
    setState(() => _messages.insert(0, textMessage));

    // TODO: Send message over Tor tunneled socket to peerId
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.peerName)),
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
