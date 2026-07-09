import 'package:flutter/widgets.dart';
import 'package:prysm/ui/core/prysm_icons.dart';
import 'package:prysm/ui/core/prysm_progress.dart';
import 'package:prysm/ui/core/prysm_app.dart';
import 'package:prysm/ui/core/prysm_toast.dart';
import 'package:prysm/theme/prysm_style_scope.dart';
import 'dart:async';
import 'dart:convert';

import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:image_picker/image_picker.dart';
import 'package:prysm/constants/group_constants.dart';
import 'package:prysm/models/contact.dart';
import 'package:prysm/models/group.dart';
import 'package:prysm/services/group_service.dart';
import 'package:prysm/screens/chat_media_gallery_screen.dart';
import 'package:prysm/screens/widgets/contact_avatar.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/screens/widgets/conversation_prefs_tiles.dart';
import 'package:prysm/screens/widgets/notification_mute_tile.dart';
import 'package:prysm/services/notification_mute_service.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/ui/core/prysm_button.dart';
import 'package:prysm/ui/prysm_scaffold.dart';
import 'package:prysm/ui/core/prysm_divider.dart';
import 'package:prysm/ui/core/prysm_list_row.dart';
import 'package:prysm/ui/core/prysm_dialog.dart';
import 'package:prysm/ui/core/prysm_text_field.dart';

class GroupSettingsScreen extends StatefulWidget {
  final Group group;
  final String userId;
  final List<Contact> contacts;
  final KeyManager keyManager;
  final VoidCallback onChanged;
  final VoidCallback onLeftOrDeleted;
  final VoidCallback? onArchived;

  const GroupSettingsScreen({
    required this.group,
    required this.userId,
    required this.contacts,
    required this.keyManager,
    required this.onChanged,
    required this.onLeftOrDeleted,
    this.onArchived,
    super.key,
  });

  @override
  State<GroupSettingsScreen> createState() => _GroupSettingsScreenState();
}

class _GroupSettingsScreenState extends State<GroupSettingsScreen> {
  late GroupService _groupService;
  List<GroupMember> _members = [];
  bool _isAdmin = false;
  bool _loading = true;
  String? _avatarBase64;
  late String _groupName;
  final Map<String, String?> _avatarByMemberId = {};

  @override
  void initState() {
    super.initState();
    _groupService = GroupService(userId: widget.userId, keyManager: widget.keyManager);
    _avatarBase64 = widget.group.avatarBase64;
    _groupName = widget.group.name;
    _load();
  }

  Future<void> _renameGroup() async {
    if (!_isAdmin) return;
    final controller = TextEditingController(text: _groupName);
    final newName = await showPrysmDialog<String>(
      context: context,
      title: 'Rename group',
      content: PrysmTextField(
        controller: controller,
        labelText: 'Group name',
        autofocus: true,
      ),
      cancelLabel: 'Cancel',
      confirmLabel: 'Save',
      onConfirm: () => Navigator.pop(context, controller.text.trim()),
    );
    if (newName == null || newName.isEmpty || newName == _groupName) return;

    try {
      await _groupService.updateGroupName(widget.group.id, newName);
      setState(() => _groupName = newName);
      widget.onChanged();
      if (mounted) {
        showPrysmToast(context, 'Group renamed');
      }
    } on GroupServiceException catch (e) {
      if (mounted) {
        showPrysmToast(context, e.message);
      }
    }
  }

  Future<void> _pickAvatar() async {
    if (!_isAdmin) return;
    final picker = ImagePicker();
    final picked = await picker.pickImage(source: ImageSource.gallery);
    if (picked == null) return;

    var bytes = await picked.readAsBytes();
    try {
      bytes = await FlutterImageCompress.compressWithList(
        bytes,
        minHeight: 1080,
        minWidth: 1080,
        quality: 70,
      );
    } catch (_) {}

    while (bytes.length > 100 * 1024) {
      bytes = await FlutterImageCompress.compressWithList(bytes, quality: 50);
      if (bytes.length > 100 * 1024) break;
    }

    final encoded = base64Encode(bytes);
    try {
      await _groupService.updateGroupAvatar(widget.group.id, encoded);
      setState(() => _avatarBase64 = encoded);
      widget.onChanged();
      if (mounted) {
        showPrysmToast(context, 'Group photo updated');
      }
    } on GroupServiceException catch (e) {
      if (mounted) {
        showPrysmToast(context, e.message);
      }
    }
  }

  Future<void> _load() async {
    final members = await _groupService.getMembers(widget.group.id);
    final admin = await _groupService.isAdmin(widget.group.id, widget.userId);
    final avatars = <String, String?>{};
    for (final member in members) {
      avatars[member.memberId] = await _resolveAvatar(member.memberId);
    }
    if (mounted) {
      setState(() {
        _members = members;
        _isAdmin = admin;
        _avatarByMemberId
          ..clear()
          ..addAll(avatars);
        _loading = false;
      });
    }

    if (admin) {
      unawaited(_groupService.syncMemberInvites(widget.group.id));
    }
  }

  Future<String?> _resolveAvatar(String memberId) async {
    final contact = widget.contacts.cast<Contact?>().firstWhere(
          (c) => c!.id == memberId,
          orElse: () => null,
        );
    if (contact?.avatarBase64 != null && contact!.avatarBase64!.isNotEmpty) {
      return contact.avatarBase64;
    }
    final user = await DBHelper.getUserById(memberId);
    final fromDb = user?['avatarBase64'] as String?;
    if (fromDb != null && fromDb.isNotEmpty) return fromDb;
    return null;
  }

  String _displayNameFor(String memberId) {
    final contact = widget.contacts.cast<Contact?>().firstWhere(
          (c) => c!.id == memberId,
          orElse: () => null,
        );
    if (contact != null) return contact.displayName;
    if (memberId == widget.userId) return 'You';
    return memberId.length > 12 ? '${memberId.substring(0, 12)}...' : memberId;
  }

  Future<void> _addMember() async {
    final available = widget.contacts
        .where((c) =>
            c.id != widget.userId &&
            !_members.any((m) => m.memberId == c.id))
        .toList();

    if (available.isEmpty) {
      showPrysmToast(context, 'No contacts available to add');
      return;
    }

    if (_members.length >= maxGroupMembers) {
      showPrysmToast(
        context,
        'Group is full ($maxGroupMembers members max)',
      );
      return;
    }

    final picked = await showPrysmSheet<Contact>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'Add member',
                style: ctx.prysmStyle.headlineStyle,
              ),
            ),
            for (final c in available)
              PrysmListRow(
                leading: ContactAvatar(
                  name: c.displayName,
                  avatarBase64: c.avatarBase64,
                  radius: 18,
                ),
                title: c.displayName,
                onTap: () => Navigator.pop(ctx, c),
              ),
          ],
        ),
      ),
    );

    if (picked == null) return;

    try {
      await _groupService.addMember(widget.group.id, picked.id);
      await _load();
      widget.onChanged();
      if (mounted) {
        showPrysmToast(context, 
              'Added ${picked.displayName}. '
              'They will receive an invite when online.',
            );
      }
    } on GroupServiceException catch (e) {
      if (mounted) {
        showPrysmToast(context, e.message);
      }
    }
  }

  Future<void> _removeMember(GroupMember member) async {
    final confirmed = await showPrysmConfirmDialog(
      context: context,
      title: 'Remove member',
      content: Text('Remove ${_displayNameFor(member.memberId)} from the group?'),
      cancelLabel: 'Cancel',
      confirmLabel: 'Remove',
      confirmVariant: PrysmButtonVariant.danger,
    );
    if (confirmed != true) return;

    try {
      await _groupService.removeMember(widget.group.id, member.memberId);
      await _load();
      widget.onChanged();
    } on GroupServiceException catch (e) {
      if (mounted) {
        showPrysmToast(context, e.message);
      }
    }
  }

  Future<void> _leaveGroup() async {
    final confirmed = await showPrysmConfirmDialog(
      context: context,
      title: 'Leave group',
      content: const Text('Leave this group?'),
      cancelLabel: 'Cancel',
      confirmLabel: 'Leave',
      confirmVariant: PrysmButtonVariant.danger,
    );
    if (confirmed != true) return;

    try {
      await _groupService.leaveGroup(widget.group.id);
      widget.onLeftOrDeleted();
      if (mounted) Navigator.of(context).pop();
    } on GroupServiceException catch (e) {
      if (mounted) {
        showPrysmToast(context, e.message);
      }
    }
  }

  Future<void> _deleteGroup() async {
    final confirmed = await showPrysmConfirmDialog(
      context: context,
      title: 'Delete group',
      content: const Text('Delete this group for everyone? This cannot be undone.'),
      cancelLabel: 'Cancel',
      confirmLabel: 'Delete',
      confirmVariant: PrysmButtonVariant.danger,
    );
    if (confirmed != true) return;

    try {
      await _groupService.deleteGroup(widget.group.id);
      widget.onLeftOrDeleted();
      if (mounted) Navigator.of(context).pop();
    } on GroupServiceException catch (e) {
      if (mounted) {
        showPrysmToast(context, e.message);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.prysmStyle.tokens;
    return PrysmPage(
      title: _groupName,
      leading: PrysmIconButton(
        icon: PrysmIcons.arrowBack,
        onPressed: () => Navigator.of(context).pop(),
      ),
      body: _loading
          ? const Center(child: PrysmProgressIndicator())
          : ListView(
              children: [
                Center(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: GestureDetector(
                      onTap: _isAdmin ? _pickAvatar : null,
                      child: Column(
                        children: [
                          ContactAvatar(
                            name: widget.group.name,
                            avatarBase64: _avatarBase64,
                            radius: 48,
                          ),
                          if (_isAdmin) ...[
                            const SizedBox(height: 8),
                            Text(
                              'Tap to change group photo',
                              style: TextStyle(
                                fontSize: 12,
                                color: tokens.textMuted,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
                if (_isAdmin)
                  PrysmListRow(
                    leading: const Icon(PrysmIcons.editOutlined),
                    title: _groupName,
                    subtitle: 'Tap to rename',
                    onTap: _renameGroup,
                  )
                else
                  PrysmListRow(
                    title: _groupName,
                    subtitle: 'Member',
                  ),
                PrysmListRow(
                  title: '${_members.length} / $maxGroupMembers members',
                  subtitle: _isAdmin ? 'You are admin' : 'Member',
                ),
                const PrysmDivider(),
                ..._members.map((m) {
                  final isSelf = m.memberId == widget.userId;
                  return PrysmListRow(
                    leading: ContactAvatar(
                      name: _displayNameFor(m.memberId),
                      avatarBase64: _avatarByMemberId[m.memberId],
                    ),
                    title: isSelf
                        ? '${_displayNameFor(m.memberId)} (you)'
                        : _displayNameFor(m.memberId),
                    subtitle: m.role == GroupRole.admin ? 'Admin' : 'Member',
                    trailing: _isAdmin && !isSelf && m.role != GroupRole.admin
                        ? PrysmIconButton(
                            icon: PrysmIcons.personRemoveOutlined,
                            onPressed: () => _removeMember(m),
                          )
                        : null,
                  );
                }),
                const PrysmDivider(),
                PrysmListRow(
                  leading: const Icon(PrysmIcons.photoLibraryOutlined),
                  title: 'Shared Media',
                  trailing: const Icon(PrysmIcons.chevronRight),
                  onTap: () async {
                    final navigator = Navigator.of(context);
                    final joinedAt = await _groupService
                        .joinedAtForCurrentUser(widget.group.id);
                    if (!mounted) return;
                    final messageId = await navigator.push<String>(
                      PrysmPageRoute(
                        page: ChatMediaGalleryScreen.group(
                          group: widget.group,
                          userId: widget.userId,
                          keyManager: widget.keyManager,
                          groupService: _groupService,
                          contacts: widget.contacts,
                          joinedAt: joinedAt,
                        ),
                      ),
                    );
                    if (messageId != null && mounted) {
                      navigator.pop(messageId);
                    }
                  },
                ),
                const PrysmDivider(),
                ConversationPrefsTiles(
                  conversationId: widget.group.id,
                  onChanged: widget.onChanged,
                  onArchived: widget.onArchived,
                ),
                const PrysmDivider(),
                NotificationMuteTile(
                  target: MuteTarget.group,
                  id: widget.group.id,
                  label: _groupName,
                ),
                const PrysmDivider(),
                if (_isAdmin && _members.length < maxGroupMembers)
                  PrysmListRow(
                    leading: const Icon(PrysmIcons.personAddOutlined),
                    title: 'Add member',
                    onTap: _addMember,
                  ),
                if (_isAdmin)
                  PrysmListRow(
                    leading: Icon(PrysmIcons.deleteOutline, color: tokens.danger),
                    titleWidget: Text(
                      'Delete group',
                      style: TextStyle(color: tokens.danger),
                    ),
                    onTap: _deleteGroup,
                  ),
                if (!_isAdmin)
                  PrysmListRow(
                    leading: Icon(PrysmIcons.exitToApp, color: tokens.danger),
                    titleWidget: Text(
                      'Leave group',
                      style: TextStyle(color: tokens.danger),
                    ),
                    onTap: _leaveGroup,
                  ),
              ],
            ),
    );
  }
}
