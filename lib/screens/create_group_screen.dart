import 'package:flutter/widgets.dart';
import 'package:prysm/ui/core/prysm_toast.dart';
import 'package:prysm/theme/prysm_style_scope.dart';
import 'dart:convert';

import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:image_picker/image_picker.dart';
import 'package:prysm/constants/group_constants.dart';
import 'package:prysm/models/contact.dart';
import 'package:prysm/models/group.dart';
import 'package:prysm/services/group_service.dart';
import 'package:prysm/screens/widgets/contact_avatar.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/ui/core/prysm_progress.dart';
import 'package:prysm/ui/core/prysm_text_field.dart';
import 'package:prysm/ui/core/prysm_divider.dart';
import 'package:prysm/ui/core/prysm_checkbox.dart';
import 'package:prysm/ui/core/prysm_button.dart';
import 'package:prysm/ui/core/prysm_icons.dart';
import 'package:prysm/ui/prysm_scaffold.dart';

class CreateGroupScreen extends StatefulWidget {
  final String userId;
  final List<Contact> contacts;
  final KeyManager keyManager;
  final void Function(Group group) onGroupCreated;

  const CreateGroupScreen({
    required this.userId,
    required this.contacts,
    required this.keyManager,
    required this.onGroupCreated,
    super.key,
  });

  @override
  State<CreateGroupScreen> createState() => _CreateGroupScreenState();
}

class _CreateGroupScreenState extends State<CreateGroupScreen> {
  final _nameController = TextEditingController();
  final Set<String> _selectedIds = {};
  String? _avatarBase64;
  bool _creating = false;

  int get _maxSelectable => maxGroupMembers - 1;

  List<Contact> get _availableContacts =>
      widget.contacts.where((c) => c.id != widget.userId).toList();

  Future<void> _create() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      showPrysmToast(context, 'Enter a group name');
      return;
    }
    if (_selectedIds.isEmpty) {
      showPrysmToast(context, 'Select at least one member');
      return;
    }

    setState(() => _creating = true);
    try {
      final service = GroupService(userId: widget.userId, keyManager: widget.keyManager);
      final group = await service.createGroup(
        name,
        _selectedIds.toList(),
        avatarBase64: _avatarBase64,
      );
      if (mounted) {
        widget.onGroupCreated(group);
        Navigator.of(context).pop();
      }
    } on GroupServiceException catch (e) {
      if (mounted) {
        showPrysmToast(context, e.message);
      }
    } catch (e) {
      if (mounted) {
        showPrysmToast(context, 'Failed to create group: $e');
      }
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  Future<void> _pickAvatar() async {
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

    setState(() => _avatarBase64 = base64Encode(bytes));
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PrysmPage(
      title: 'Create Group',
      leading: PrysmIconButton(
        icon: PrysmIcons.close,
        onPressed: () => Navigator.of(context).pop(),
      ),
      actions: [
        _creating
            ? const SizedBox(
                width: 40,
                height: 40,
                child: Center(child: PrysmProgressIndicator(size: 20)),
              )
            : PrysmTextButton(
                label: 'Create',
                onPressed: _create,
              ),
      ],
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: GestureDetector(
              onTap: _pickAvatar,
              child: Column(
                children: [
                  ContactAvatar(
                    name: _nameController.text.isNotEmpty
                        ? _nameController.text
                        : 'G',
                    avatarBase64: _avatarBase64,
                    radius: 40,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Tap to set group photo',
                    style: TextStyle(
                      fontSize: 12,
                      color: context.prysmStyle.tokens.textMuted,
                    ),
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: PrysmTextField(
              controller: _nameController,
              labelText: 'Group name',
              hintText: 'Group name',
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Text(
                  '${_selectedIds.length} / $_maxSelectable selected',
                  style: TextStyle(color: context.prysmStyle.tokens.textMuted),
                ),
                const Spacer(),
                Text(
                  'Max $maxGroupMembers members total',
                  style: TextStyle(fontSize: 12, color: context.prysmStyle.tokens.textMuted),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: _availableContacts.isEmpty
                ? const Center(child: Text('Add contacts before creating a group'))
                : ListView.builder(
                    itemCount: _availableContacts.length,
                    itemBuilder: (_, i) {
                      final contact = _availableContacts[i];
                      final selected = _selectedIds.contains(contact.id);
                      final atCap = _selectedIds.length >= _maxSelectable && !selected;
                      return PrysmCheckboxRow(
                        value: selected,
                        onChanged: atCap
                            ? null
                            : (v) {
                                setState(() {
                                  if (v) {
                                    _selectedIds.add(contact.id);
                                  } else {
                                    _selectedIds.remove(contact.id);
                                  }
                                });
                              },
                        secondary: ContactAvatar(
                          name: contact.displayName,
                          avatarBase64: contact.avatarBase64,
                        ),
                        title: contact.displayName,
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
