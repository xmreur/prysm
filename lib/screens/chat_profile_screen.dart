import 'package:flutter/widgets.dart';
import 'package:prysm/ui/core/prysm_icons.dart';
import 'package:prysm/ui/core/prysm_app.dart';
import 'package:prysm/theme/prysm_style_scope.dart';
import 'dart:convert';
import 'package:bs58/bs58.dart';
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
import 'package:prysm/ui/core/prysm_button.dart';
import 'package:prysm/ui/prysm_scaffold.dart';
import 'package:prysm/ui/core/prysm_list_row.dart';
import 'package:prysm/ui/core/prysm_dialog.dart';
import 'package:prysm/ui/core/prysm_text_field.dart';
import 'package:prysm/ui/core/prysm_toast.dart';

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
    showPrysmConfirmDialog(
      context: context,
      title: 'Delete Chat',
      content: const Text(
        'Are you sure you want to delete all messages in this chat? This cannot be undone.',
      ),
      cancelLabel: 'Cancel',
      confirmLabel: 'Delete',
      confirmVariant: PrysmButtonVariant.danger,
    ).then((confirmed) {
      if (confirmed != true) return;
      widget.onDeleteChat();
      widget.onClose();
    });
  }

  void _confirmDeleteContact() {
    showPrysmConfirmDialog(
      context: context,
      title: 'Delete Contact',
      content: const Text(
        'Are you sure you want to delete this contact? This cannot be undone.',
      ),
      cancelLabel: 'Cancel',
      confirmLabel: 'Delete',
      confirmVariant: PrysmButtonVariant.danger,
    ).then((confirmed) {
      if (confirmed != true) return;
      widget.onDeleteContact();
      widget.onClose();
    });
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.prysmStyle.tokens;
    return PrysmPage(
      title: 'Contact Info',
      headerHeight: 70,
      leading: PrysmIconButton(
        icon: PrysmIcons.arrowBack,
        onPressed: widget.onClose,
      ),
      actions: [
        if (!_isBlocked)
          PrysmIconButton(
            icon: PrysmIcons.saveOutlined,
            tooltip: 'Save',
            onPressed: _saveName,
          ),
      ],
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            children: [
              // Profile header
              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: context.prysmStyle.tokens.surface,
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF000000).withValues(alpha: 0.05),
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
                            PrysmIcons.block,
                            size: 16,
                            color: context.prysmStyle.tokens.textMuted,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            'Blocked',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w500,
                              color: context.prysmStyle.tokens.textMuted,
                            ),
                          ),
                        ],
                      ),
                    ] else ...[
                      PrysmTextField(
                        controller: _nameController,
                        labelText: 'Display Name',
                      ),
                      const SizedBox(height: 8),
                      if (widget.isOnline == null)
                        Text(
                          'Checking...',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w500,
                            color: context.prysmStyle.tokens.textMuted,
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
                                    ? const Color(0xFF4CAF50)
                                    : tokens.textMuted.withValues(alpha: 0.4),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              widget.isOnline! ? 'Online' : 'Offline',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w500,
                                color: widget.isOnline!
                                    ? const Color(0xFF4CAF50)
                                    : context.prysmStyle.tokens.textMuted,
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
                  color: context.prysmStyle.tokens.surface,
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF000000).withValues(alpha: 0.05),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Column(
                  children: [
                    PrysmListRow(
                      leading: const Icon(PrysmIcons.keyOutlined),
                      title: 'User ID',
                      subtitleWidget: Text(
                        encodeOnionToBase58(widget.peer.id),
                        style: const TextStyle(
                          fontSize: 12,
                          fontFamily: 'monospace',
                        ),
                      ),
                      onTap: () {
                        Clipboard.setData(ClipboardData(text: widget.peer.id));
                        showPrysmToast(context, 'ID copied to clipboard');
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              Container(
                decoration: BoxDecoration(
                  color: context.prysmStyle.tokens.surface,
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF000000).withValues(alpha: 0.05),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: PrysmListRow(
                  leading: const Icon(PrysmIcons.photoLibraryOutlined),
                  title: 'Shared Media',
                  trailing: const Icon(PrysmIcons.chevronRight),
                  onTap: () async {
                    final messageId = await Navigator.push<String>(
                      context,
                      PrysmPageRoute(page: ChatMediaGalleryScreen.direct(
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
                  color: context.prysmStyle.tokens.surface,
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF000000).withValues(alpha: 0.05),
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
                  color: context.prysmStyle.tokens.surface,
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF000000).withValues(alpha: 0.05),
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
                  color: context.prysmStyle.tokens.surface,
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF000000).withValues(alpha: 0.05),
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
                  color: context.prysmStyle.tokens.surface,
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF000000).withValues(alpha: 0.05),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Column(
                  children: [
                    PrysmListRow(
                      leading: Icon(
                        PrysmIcons.deleteOutline,
                        color: tokens.danger,
                      ),
                      titleWidget: Text(
                        'Delete Chat',
                        style: TextStyle(color: tokens.danger),
                      ),
                      subtitle: 'Delete all messages in this chat',
                      onTap: _confirmDeleteChat,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 40),
              // Action buttons
              Container(
                decoration: BoxDecoration(
                  color: context.prysmStyle.tokens.surface,
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF000000).withValues(alpha: 0.05),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Column(
                  children: [
                    PrysmListRow(
                      leading: Icon(
                        PrysmIcons.deleteOutline,
                        color: tokens.danger,
                      ),
                      titleWidget: Text(
                        'Delete Contact',
                        style: TextStyle(color: tokens.danger),
                      ),
                      subtitle:
                          'Delete this contact from your list. Cannot be undone.',
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
