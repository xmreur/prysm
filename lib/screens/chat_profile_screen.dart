import 'dart:convert';
import 'package:bs58/bs58.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:prysm/services/block_service.dart';
import 'package:prysm/services/notification_mute_service.dart';
import '../models/contact.dart';
import '../util/db_helper.dart';
import '../util/key_manager.dart';
import 'chat_media_gallery_screen.dart';
import 'widgets/block_user_tile.dart';
import 'widgets/contact_avatar.dart';
import 'widgets/conversation_prefs_tiles.dart';
import 'widgets/notification_mute_tile.dart';

class ChatProfileScreen extends StatefulWidget {
  final Contact peer;
  final String currentUserName;
  final bool? isOnline;
  final VoidCallback onClose;
  final Function(Contact) onUpdateName;
  final Function() onDeleteChat;
  final Function() onDeleteContact;
  final VoidCallback onPreferencesChanged;
  final VoidCallback? onArchived;
  final VoidCallback? onBlocked;
  final VoidCallback? onUnblocked;
  final String userId;
  final KeyManager keyManager;

  const ChatProfileScreen({
    required this.peer,
    required this.currentUserName,
    this.isOnline,
    required this.onClose,
    required this.onUpdateName,
    required this.onDeleteChat,
    required this.onDeleteContact,
    required this.onPreferencesChanged,
    this.onArchived,
    this.onBlocked,
    this.onUnblocked,
    required this.userId,
    required this.keyManager,
    super.key,
  });

  @override
  State<ChatProfileScreen> createState() => _ChatProfileScreenState();
}

class _ChatProfileScreenState extends State<ChatProfileScreen> {
  late TextEditingController _nameController;

  bool get _isBlocked => BlockService.instance.isBlocked(widget.peer.id);

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.peer.displayName);
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  String encodeOnionToBase58(String onion) {
    // Remove trailing '.onion' if present
    final cleanOnion = onion.endsWith('.onion')
        ? onion.substring(0, onion.length - 6)
        : onion;

    // Convert string to UTF8 bytes
    final bytes = utf8.encode(cleanOnion);

    // Encode bytes into Base58 string
    return base58.encode(Uint8List.fromList(bytes));
  }

  void _saveName() async {
    if (!context.mounted) return;
    final navigator = Navigator.of(context);
    final newCustomName = _nameController.text.trim();
    final updatedPeer = Contact(
      id: widget.peer.id,
      name: widget.peer.name,
      avatarUrl: widget.peer.avatarUrl,
      avatarBase64: widget.peer.avatarBase64,
      customName: newCustomName.isNotEmpty ? newCustomName : null,
      identityJson: widget.peer.identityJson,
    );

    // Only update customName column — don't overwrite remote name/avatar/key
    await DBHelper.updateUserFields(updatedPeer.id, {
      'customName': newCustomName.isNotEmpty ? newCustomName : null,
    });

    if (!context.mounted) return;
    widget.onUpdateName(updatedPeer);
    navigator.pop(updatedPeer);
  }

  void _confirmDeleteChat() {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Delete Chat'),
          content: const Text(
            'Are you sure you want to delete all messages in this chat? This cannot be undone.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
                widget.onDeleteChat();
                widget.onClose();
              },
              child: const Text('Delete', style: TextStyle(color: Colors.red)),
            ),
          ],
        );
      },
    );
  }

  void _confirmDeleteContact() {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Delete Contact'),
          content: const Text(
            'Are you sure you want to delete this contact? This cannot be undone.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
                widget.onDeleteContact();
                widget.onClose();
              },
              child: const Text('Delete', style: TextStyle(color: Colors.red)),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 70,
        title: const Text(
          'Contact Info',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: widget.onClose,
        ),
        actions: [
          if (!_isBlocked)
            IconButton(
              icon: const Icon(Icons.save_outlined),
              onPressed: _saveName,
              tooltip: 'Save',
            ),
        ],
        elevation: 2,
        shadowColor: Colors.black.withValues(alpha: 0.1),
      ),
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            children: [
              // Profile header
              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: Theme.of(context).cardColor,
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.05),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Column(
                  children: [
                    ContactAvatar(
                      name: widget.peer.displayName,
                      radius: 50,
                      avatarBase64: widget.peer.avatarBase64,
                    ),
                    const SizedBox(height: 20),
                    if (_isBlocked) ...[
                      Text(
                        widget.peer.displayName,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.block,
                            size: 16,
                            color: Theme.of(context).hintColor,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            'Blocked',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w500,
                              color: Theme.of(context).hintColor,
                            ),
                          ),
                        ],
                      ),
                    ] else ...[
                      TextField(
                        controller: _nameController,
                        decoration: const InputDecoration(
                          labelText: 'Display Name',
                          border: OutlineInputBorder(),
                        ),
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      if (widget.isOnline == null)
                        Text(
                          'Checking...',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w500,
                            color: Theme.of(context).hintColor,
                          ),
                        )
                      else
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Container(
                              width: 10,
                              height: 10,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: widget.isOnline!
                                    ? Colors.green
                                    : Theme.of(context)
                                        .colorScheme
                                        .onSurface
                                        .withAlpha(100),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              widget.isOnline! ? 'Online' : 'Offline',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w500,
                                color: widget.isOnline!
                                    ? Colors.green
                                    : Theme.of(context).hintColor,
                              ),
                            ),
                          ],
                        ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 20),
              if (!_isBlocked) ...[
              // Profile details
              Container(
                decoration: BoxDecoration(
                  color: Theme.of(context).cardColor,
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.05),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Column(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.key_outlined),
                      title: const Text('User ID'),
                      subtitle: SelectableText(
                        encodeOnionToBase58(widget.peer.id),
                        style: const TextStyle(
                          fontSize: 12,
                          fontFamily: 'monospace',
                        ),
                      ),
                      onTap: () {
                        Clipboard.setData(ClipboardData(text: widget.peer.id));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('ID copied to clipboard'),
                            duration: Duration(seconds: 2),
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              Container(
                decoration: BoxDecoration(
                  color: Theme.of(context).cardColor,
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.05),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: ListTile(
                  leading: const Icon(Icons.photo_library_outlined),
                  title: const Text('Shared Media'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () async {
                    final messageId = await Navigator.push<String>(
                      context,
                      MaterialPageRoute(
                        builder: (_) => ChatMediaGalleryScreen.direct(
                          peer: widget.peer,
                          userId: widget.userId,
                          keyManager: widget.keyManager,
                        ),
                      ),
                    );
                    if (messageId != null && context.mounted) {
                      Navigator.of(context).pop(messageId);
                    }
                  },
                ),
              ),
              const SizedBox(height: 20),
              Container(
                decoration: BoxDecoration(
                  color: Theme.of(context).cardColor,
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.05),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: ConversationPrefsTiles(
                  conversationId: widget.peer.id,
                  onChanged: widget.onPreferencesChanged,
                  onArchived: widget.onArchived,
                ),
              ),
              const SizedBox(height: 20),
              Container(
                decoration: BoxDecoration(
                  color: Theme.of(context).cardColor,
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.05),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: NotificationMuteTile(
                  target: MuteTarget.user,
                  id: widget.peer.id,
                  label: widget.peer.displayName,
                ),
              ),
              const SizedBox(height: 20),
              ],
              Container(
                decoration: BoxDecoration(
                  color: Theme.of(context).cardColor,
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.05),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: BlockUserTile(
                  peerId: widget.peer.id,
                  onBlocked: () {
                    widget.onBlocked?.call();
                    setState(() {});
                  },
                  onUnblocked: () {
                    widget.onUnblocked?.call();
                    setState(() {});
                  },
                ),
              ),
              const SizedBox(height: 20),
              Container(
                decoration: BoxDecoration(
                  color: Theme.of(context).cardColor,
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.05),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Column(
                  children: [
                    ListTile(
                      leading: const Icon(
                        Icons.delete_outline,
                        color: Colors.red,
                      ),
                      title: const Text(
                        'Delete Chat',
                        style: TextStyle(color: Colors.red),
                      ),
                      subtitle: const Text('Delete all messages in this chat'),
                      onTap: _confirmDeleteChat,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 40),
              // Action buttons
              Container(
                decoration: BoxDecoration(
                  color: Theme.of(context).cardColor,
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.05),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Column(
                  children: [
                    ListTile(
                      leading: const Icon(
                        Icons.delete_outline,
                        color: Colors.red,
                      ),
                      title: const Text(
                        'Delete Contact',
                        style: TextStyle(color: Colors.red),
                      ),
                      subtitle: const Text(
                        'Delete this contact from your list. Cannot be undone.',
                      ),
                      onTap: _confirmDeleteContact,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
