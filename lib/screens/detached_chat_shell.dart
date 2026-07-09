import 'package:flutter/widgets.dart';
import 'package:prysm/ui/core/prysm_progress.dart';
import 'package:prysm/models/contact.dart';
import 'package:prysm/models/detached_chat_launch.dart';
import 'package:prysm/models/group.dart';
import 'package:prysm/screens/chat.dart';
import 'package:prysm/screens/group_chat.dart';
import 'package:prysm/screens/self_chat_screen.dart';
import 'package:prysm/services/active_conversation_tracker.dart';
import 'package:prysm/services/detached_chat_client.dart';
import 'package:prysm/services/settings_service.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/tor_service.dart';
import 'package:prysm/ui/prysm_scaffold.dart';
import 'package:prysm/ui/core/prysm_button.dart';
import 'package:window_manager/window_manager.dart';

class DetachedChatShell extends StatefulWidget {
  final DetachedChatLaunch launch;
  final KeyManager keyManager;
  final TorManager torManager;
  final SettingsService settings;

  const DetachedChatShell({
    required this.launch,
    required this.keyManager,
    required this.torManager,
    required this.settings,
    super.key,
  });

  @override
  State<DetachedChatShell> createState() => _DetachedChatShellState();
}

class _DetachedChatShellState extends State<DetachedChatShell> with WindowListener {
  late final DetachedChatClient _client;
  bool _loading = true;
  String? _error;
  Contact? _contact;
  Group? _group;
  List<Contact> _contacts = const [];

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _client = DetachedChatClient(
      launch: widget.launch,
      windowId: widget.launch.conversationId,
    );
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    try {
      await windowManager.ensureInitialized();
      await windowManager.setTitle(widget.launch.title);
      await windowManager.setSize(const Size(900, 700));
      await windowManager.center();
      await windowManager.show();
      await windowManager.focus();

      await _client.init();

      switch (widget.launch.chatKind!) {
        case DetachedChatKind.direct:
          final user = await DBHelper.getUserById(widget.launch.conversationId);
          if (user == null) {
            throw StateError('Contact not found');
          }
          _contact = Contact(
            id: user['id'] as String,
            name: user['name'] as String,
            avatarUrl: '',
            avatarBase64: user['avatarBase64'] as String?,
            customName: user['customName'] as String?,
            identityJson: (user['identityJson'] as String?) ??
                (user['publicKeyPem'] as String?) ??
                '',
          );
        case DetachedChatKind.group:
          final groupRow = await DBHelper.getGroupById(widget.launch.conversationId);
          if (groupRow == null) {
            throw StateError('Group not found');
          }
          _group = Group.fromMap(groupRow);
          final users = await DBHelper.getUsers();
          _contacts = users
              .map(
                (map) => Contact(
                  id: map['id'] as String,
                  name: map['name'] as String,
                  avatarUrl: '',
                  avatarBase64: map['avatarBase64'] as String?,
                  customName: map['customName'] as String?,
                  identityJson: (map['identityJson'] as String?) ??
                      (map['publicKeyPem'] as String?) ??
                      '',
                ),
              )
              .toList();
        case DetachedChatKind.self:
          break;
      }

      if (!mounted) return;
      _syncActiveConversationTracker();
      setState(() {
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  void _syncActiveConversationTracker() {
    switch (widget.launch.chatKind!) {
      case DetachedChatKind.direct:
        ActiveConversationTracker.instance.setDirect(widget.launch.conversationId);
      case DetachedChatKind.group:
        ActiveConversationTracker.instance.setGroup(widget.launch.conversationId);
      case DetachedChatKind.self:
        break;
    }
  }

  @override
  void onWindowFocus() {
    _syncActiveConversationTracker();
  }

  @override
  void onWindowBlur() {
    ActiveConversationTracker.instance.clear();
  }

  Future<void> _closeWindow() async {
    await windowManager.close();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    ActiveConversationTracker.instance.clear();
    _client.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const PrysmPage(
        body: Center(child: PrysmProgressIndicator()),
      );
    }

    if (_error != null) {
      return PrysmPage(
        title: widget.launch.title,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              'Could not open chat.\n\n$_error\n\nKeep the main Prysm window open.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    switch (widget.launch.chatKind!) {
      case DetachedChatKind.direct:
        final contact = _contact!;
        return ChatScreen(
          userId: widget.launch.userId,
          userName: widget.launch.userName,
          peerId: contact.id,
          peerName: contact.displayName,
          peerAvatarBase64: contact.avatarBase64,
          peerPublicKeyPem: contact.publicKeyPem,
          torManager: widget.torManager,
          keyManager: widget.keyManager,
          currentTheme: widget.launch.themeIndex,
          clearChat: _closeWindow,
          reloadUsers: () {},
          onCloseChat: _closeWindow,
          detachedClient: _client,
        );
      case DetachedChatKind.group:
        final group = _group!;
        return GroupChatScreen(
          userId: widget.launch.userId,
          group: group,
          contacts: _contacts,
          keyManager: widget.keyManager,
          reloadConversations: () {},
          onCloseChat: _closeWindow,
          detachedClient: _client,
        );
      case DetachedChatKind.self:
        return SelfChatScreen(
          userId: widget.launch.userId,
          userName: widget.launch.userName,
          avatarBase64: widget.launch.avatarBase64,
          keyManager: widget.keyManager,
          onCloseChat: _closeWindow,
          reloadSidebar: () {},
          detachedClient: _client,
        );
    }
  }
}
