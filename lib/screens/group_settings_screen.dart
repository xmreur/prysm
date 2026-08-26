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
import 'package:prysm/screens/chat_media_gallery_screen.dart';
import 'package:prysm/screens/pinned_messages_screen.dart';
import 'package:prysm/database/pinned_messages_db.dart';
import 'package:prysm/screens/key_verification_screen.dart';
import 'package:prysm/services/contact_verification_service.dart';
import 'package:prysm/services/group_service.dart';
import 'package:prysm/screens/widgets/contact_avatar.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/screens/widgets/conversation_prefs_tiles.dart';
import 'package:prysm/screens/widgets/notification_mute_tile.dart';
import 'package:prysm/screens/widgets/scheduled_messages_tile.dart';
import 'package:prysm/screens/widgets/disappearing_messages_tile.dart';
import 'package:prysm/services/notification_mute_service.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/ui/core/prysm_button.dart';
import 'package:prysm/ui/prysm_scaffold.dart';
import 'package:prysm/ui/core/prysm_divider.dart';
import 'package:prysm/ui/core/prysm_list_row.dart';
import 'package:prysm/ui/core/prysm_dialog.dart';
import 'package:prysm/ui/core/prysm_text_field.dart';
import 'package:prysm/l10n/l10n_extensions.dart';

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
  final _verificationService = ContactVerificationService.instance;
  List<GroupMember> _members = [];
  bool _isAdmin = false;
  bool _loading = true;
  String? _avatarBase64;
  late String _groupName;
  final Map<String, String?> _avatarByMemberId = {};
  final Map<String, Contact> _contactByMemberId = {};

  @override
  void initState() {
    super.initState();
    _groupService = GroupService(
      userId: widget.userId,
      keyManager: widget.keyManager,
    );
    _avatarBase64 = widget.group.avatarBase64;
    _groupName = widget.group.name;
    _load();
  }

  Future<void> _renameGroup() async {
    if (!_isAdmin) return;
    final controller = TextEditingController(text: _groupName);
    final newName = await showPrysmDialog<String>(
      context: context,
      title: context.l10n.renameGroup,
      content: PrysmTextField(
        controller: controller,
        labelText: context.l10n.groupName,
        autofocus: true,
      ),
      cancelLabel: context.l10n.cancel,
      confirmLabel: context.l10n.save,
      onConfirm: () => Navigator.pop(context, controller.text.trim()),
    );
    if (newName == null || newName.isEmpty || newName == _groupName) return;

    try {
      await _groupService.updateGroupName(widget.group.id, newName);
      setState(() => _groupName = newName);
      widget.onChanged();
      if (mounted) {
        showPrysmToast(context, context.l10n.groupRenamed);
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
        showPrysmToast(context, context.l10n.groupPhotoUpdated);
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
    final contacts = <String, Contact>{};
    for (final member in members) {
      avatars[member.memberId] = await _resolveAvatar(member.memberId);
      final contact = await _contactForMember(member.memberId);
      if (contact != null) {
        contacts[member.memberId] = contact;
      }
    }
    if (mounted) {
      setState(() {
        _members = members;
        _isAdmin = admin;
        _avatarByMemberId
          ..clear()
          ..addAll(avatars);
        _contactByMemberId
          ..clear()
          ..addAll(contacts);
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
    if (memberId == widget.userId) return context.l10n.you;
    return memberId.length > 12 ? '${memberId.substring(0, 12)}...' : memberId;
  }

  Future<Contact?> _contactForMember(String memberId) async {
    final inMemory = widget.contacts.cast<Contact?>().firstWhere(
      (c) => c!.id == memberId,
      orElse: () => null,
    );
    if (inMemory != null) return inMemory;

    final user = await DBHelper.getUserById(memberId);
    if (user == null) return null;
    return Contact.fromMap(user);
  }

  Future<void> _openMemberVerification(String memberId) async {
    final contact = await _contactForMember(memberId);
    if (contact == null) {
      if (mounted) {
        showPrysmToast(context, context.l10n.contactNotFound);
      }
      return;
    }

    if (!mounted) return;

    final result = await Navigator.push<Contact>(
      context,
      PrysmPageRoute(
        page: KeyVerificationScreen(
          peer: contact,
          keyManager: widget.keyManager,
          onVerificationChanged: () {
            if (mounted) _load();
          },
        ),
      ),
    );
    if (result != null && mounted) {
      await _load();
    }
  }

  Widget? _verificationBadge(Contact? contact) {
    if (contact == null) return null;
    switch (_verificationService.statusFor(contact)) {
      case VerificationStatus.verified:
        return const Icon(
          PrysmIcons.checkCircle,
          color: Color(0xFF4CAF50),
          size: 18,
        );
      case VerificationStatus.keyChanged:
        return const Icon(
          PrysmIcons.warning,
          color: Color(0xFFFF9800),
          size: 18,
        );
      case VerificationStatus.unverified:
        return null;
    }
  }

  Future<void> _addMember() async {
    final available = widget.contacts
        .where(
          (c) =>
              c.id != widget.userId && !_members.any((m) => m.memberId == c.id),
        )
        .toList();

    if (available.isEmpty) {
      showPrysmToast(context, context.l10n.noContactsAvailableToAdd);
      return;
    }

    if (_members.length >= maxGroupMembers) {
      showPrysmToast(context, 'Group is full ($maxGroupMembers members max)');
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
              child: Text('Add member', style: ctx.prysmStyle.headlineStyle),
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
        showPrysmToast(
          context,
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
      title: context.l10n.removeMember,
      content: Text(
        context.l10n.removeMemberFromGroupQuestion(
          _displayNameFor(member.memberId),
        ),
      ),
      cancelLabel: context.l10n.cancel,
      confirmLabel: context.l10n.remove,
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
      title: context.l10n.leaveGroup,
      content: Text(context.l10n.leaveThisGroup),
      cancelLabel: context.l10n.cancel,
      confirmLabel: context.l10n.leaveAction,
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
      title: context.l10n.deleteGroup,
      content: Text(context.l10n.deleteThisGroupForEveryoneThisCannotBe),
      cancelLabel: context.l10n.cancel,
      confirmLabel: context.l10n.delete,
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
                    subtitle: context.l10n.tapToRename,
                    onTap: _renameGroup,
                  )
                else
                  PrysmListRow(title: _groupName, subtitle: context.l10n.member),
                PrysmListRow(
                  title: '${_members.length} / $maxGroupMembers members',
                  subtitle: _isAdmin
                      ? context.l10n.youAreAdmin
                      : context.l10n.member,
                ),
                const PrysmDivider(),
                ..._members.map((m) {
                  final isSelf = m.memberId == widget.userId;
                  final memberContact = _contactByMemberId[m.memberId];
                  final badge = _verificationBadge(memberContact);
                  return PrysmListRow(
                    leading: ContactAvatar(
                      name: _displayNameFor(m.memberId),
                      avatarBase64: _avatarByMemberId[m.memberId],
                    ),
                    title: isSelf
                        ? context.l10n.memberDisplayNameWithYou(
                            _displayNameFor(m.memberId),
                            context.l10n.you,
                          )
                        : _displayNameFor(m.memberId),
                    subtitle: m.role == GroupRole.admin
                        ? context.l10n.admin
                        : context.l10n.member,
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (!isSelf && badge != null) badge,
                        if (!isSelf && badge != null) const SizedBox(width: 4),
                        if (_isAdmin && !isSelf && m.role != GroupRole.admin)
                          PrysmIconButton(
                            icon: PrysmIcons.personRemoveOutlined,
                            onPressed: () => _removeMember(m),
                          )
                        else if (!isSelf)
                          const Icon(PrysmIcons.chevronRight, size: 18),
                      ],
                    ),
                    onTap: isSelf
                        ? null
                        : () => _openMemberVerification(m.memberId),
                  );
                }),
                const PrysmDivider(),
                PrysmListRow(
                  leading: const Icon(PrysmIcons.photoLibraryOutlined),
                  title: context.l10n.sharedMedia,
                  trailing: const Icon(PrysmIcons.chevronRight),
                  onTap: () async {
                    final navigator = Navigator.of(context);
                    final joinedAt = await _groupService.joinedAtForCurrentUser(
                      widget.group.id,
                    );
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
                PrysmListRow(
                  leading: const Icon(PrysmIcons.pushPin),
                  title: context.l10n.pinnedMessages,
                  trailing: const Icon(PrysmIcons.chevronRight),
                  onTap: () async {
                    final navigator = Navigator.of(context);
                    final messageId = await navigator.push<String>(
                      PrysmPageRoute(
                        page: PinnedMessagesScreen(
                          conversationId: widget.group.id,
                          scope: PinnedMessagesDb.scopeGroup,
                          keyManager: widget.keyManager,
                          userId: widget.userId,
                          groupService: _groupService,
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
                ScheduledMessagesTile(
                  userId: widget.userId,
                  keyManager: widget.keyManager,
                  conversationId: widget.group.id,
                ),
                DisappearingMessagesTile(
                  conversationId: widget.group.id,
                  userId: widget.userId,
                  keyManager: widget.keyManager,
                  isGroup: true,
                  groupService: _groupService,
                  memberIds: _members.map((m) => m.memberId).toList(),
                ),
                if (_isAdmin && _members.length < maxGroupMembers)
                  PrysmListRow(
                    leading: const Icon(PrysmIcons.personAddOutlined),
                    title: context.l10n.addMember,
                    onTap: _addMember,
                  ),
                if (_isAdmin)
                  PrysmListRow(
                    leading: Icon(
                      PrysmIcons.deleteOutline,
                      color: tokens.danger,
                    ),
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
