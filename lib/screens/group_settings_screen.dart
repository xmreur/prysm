import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:image_picker/image_picker.dart';
import 'package:prysm/constants/group_constants.dart';
import 'package:prysm/models/contact.dart';
import 'package:prysm/models/group.dart';
import 'package:prysm/services/group_service.dart';
import 'package:prysm/screens/widgets/contact_avatar.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/screens/widgets/conversation_prefs_tiles.dart';
import 'package:prysm/screens/widgets/notification_mute_tile.dart';
import 'package:prysm/services/notification_mute_service.dart';
import 'package:prysm/util/key_manager.dart';

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
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename group'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(labelText: 'Group name'),
          autofocus: true,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (newName == null || newName.isEmpty || newName == _groupName) return;

    try {
      await _groupService.updateGroupName(widget.group.id, newName);
      setState(() => _groupName = newName);
      widget.onChanged();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Group renamed')),
        );
      }
    } on GroupServiceException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
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
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Group photo updated')),
        );
      }
    } on GroupServiceException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No contacts available to add')),
      );
      return;
    }

    if (_members.length >= maxGroupMembers) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Group is full ($maxGroupMembers members max)')),
      );
      return;
    }

    final picked = await showDialog<Contact>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Add member'),
        children: available
            .map((c) => SimpleDialogOption(
                  onPressed: () => Navigator.pop(ctx, c),
                  child: Row(
                    children: [
                      ContactAvatar(
                        name: c.displayName,
                        avatarBase64: c.avatarBase64,
                        radius: 18,
                      ),
                      const SizedBox(width: 12),
                      Text(c.displayName),
                    ],
                  ),
                ))
            .toList(),
      ),
    );

    if (picked == null) return;

    try {
      await _groupService.addMember(widget.group.id, picked.id);
      await _load();
      widget.onChanged();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Added ${picked.displayName}. '
              'They will receive an invite when online.',
            ),
          ),
        );
      }
    } on GroupServiceException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
      }
    }
  }

  Future<void> _removeMember(GroupMember member) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove member'),
        content: Text('Remove ${_displayNameFor(member.memberId)} from the group?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Remove')),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await _groupService.removeMember(widget.group.id, member.memberId);
      await _load();
      widget.onChanged();
    } on GroupServiceException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
      }
    }
  }

  Future<void> _leaveGroup() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Leave group'),
        content: const Text('Leave this group?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Leave')),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await _groupService.leaveGroup(widget.group.id);
      widget.onLeftOrDeleted();
      if (mounted) Navigator.of(context).pop();
    } on GroupServiceException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
      }
    }
  }

  Future<void> _deleteGroup() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete group'),
        content: const Text('Delete this group for everyone? This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await _groupService.deleteGroup(widget.group.id);
      widget.onLeftOrDeleted();
      if (mounted) Navigator.of(context).pop();
    } on GroupServiceException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_groupName)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
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
                              style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
                if (_isAdmin)
                  ListTile(
                    leading: const Icon(Icons.edit_outlined),
                    title: Text(_groupName),
                    subtitle: const Text('Tap to rename'),
                    onTap: _renameGroup,
                  )
                else
                  ListTile(
                    title: Text(_groupName),
                    subtitle: const Text('Member'),
                  ),
                ListTile(
                  title: Text('${_members.length} / $maxGroupMembers members'),
                  subtitle: Text(_isAdmin ? 'You are admin' : 'Member'),
                ),
                const Divider(),
                ..._members.map((m) {
                  final isSelf = m.memberId == widget.userId;
                  return ListTile(
                    leading: ContactAvatar(
                      name: _displayNameFor(m.memberId),
                      avatarBase64: _avatarByMemberId[m.memberId],
                    ),
                    title: Text(isSelf ? '${_displayNameFor(m.memberId)} (you)' : _displayNameFor(m.memberId)),
                    subtitle: Text(m.role == GroupRole.admin ? 'Admin' : 'Member'),
                    trailing: _isAdmin && !isSelf && m.role != GroupRole.admin
                        ? IconButton(
                            icon: const Icon(Icons.person_remove_outlined),
                            onPressed: () => _removeMember(m),
                          )
                        : null,
                  );
                }),
                const Divider(),
                ConversationPrefsTiles(
                  conversationId: widget.group.id,
                  onChanged: widget.onChanged,
                  onArchived: widget.onArchived,
                ),
                const Divider(),
                NotificationMuteTile(
                  target: MuteTarget.group,
                  id: widget.group.id,
                  label: _groupName,
                ),
                const Divider(),
                if (_isAdmin && _members.length < maxGroupMembers)
                  ListTile(
                    leading: const Icon(Icons.person_add_outlined),
                    title: const Text('Add member'),
                    onTap: _addMember,
                  ),
                if (_isAdmin)
                  ListTile(
                    leading: const Icon(Icons.delete_outline, color: Colors.red),
                    title: const Text('Delete group', style: TextStyle(color: Colors.red)),
                    onTap: _deleteGroup,
                  ),
                if (!_isAdmin)
                  ListTile(
                    leading: const Icon(Icons.exit_to_app, color: Colors.red),
                    title: const Text('Leave group', style: TextStyle(color: Colors.red)),
                    onTap: _leaveGroup,
                  ),
              ],
            ),
    );
  }
}
