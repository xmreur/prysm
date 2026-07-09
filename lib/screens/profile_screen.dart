import 'package:flutter/widgets.dart';
import 'package:prysm/ui/core/prysm_icons.dart';
import 'package:prysm/ui/core/prysm_app.dart';
import 'package:prysm/theme/prysm_style_scope.dart';
import 'dart:convert';
import 'package:prysm/ui/prysm_scaffold.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/screens/widgets/contact_avatar.dart';
import 'package:prysm/screens/widgets/prysm_id_qr.dart';
import 'package:prysm/util/onion_id_codec.dart';
import '../models/contact.dart';
import 'privacy_settings_screen.dart';
import 'package:prysm/screens/about_screen.dart';
import 'package:prysm/ui/core/prysm_button.dart';
import 'package:prysm/ui/core/prysm_divider.dart';
import 'package:prysm/ui/core/prysm_list_row.dart';
import 'package:prysm/ui/core/prysm_dialog.dart';
import 'package:prysm/ui/core/prysm_text_field.dart';
import 'package:prysm/ui/core/prysm_toast.dart';

typedef ValueChanged<T> = void Function(T value);

class ProfileScreen extends StatefulWidget {
  final Contact user;
  final VoidCallback onClose;
  final ValueChanged<Contact> onUpdate;
  final Function() reloadUsers;
  final ValueChanged<String>? onScanResult;
  const ProfileScreen({
    required this.user,
    required this.onClose,
    required this.onUpdate,
    required this.reloadUsers,
    this.onScanResult,
    super.key,
  });

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  late TextEditingController _nameController;
  late String name = widget.user.name;
  String? _avatarBase64;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: name);
    _avatarBase64 = widget.user.avatarBase64;
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  void _saveProfile() {
    final updatedUser = Contact(
      id: widget.user.id,
      name: name,
      avatarUrl: widget.user.avatarUrl,
      avatarBase64: _avatarBase64,
      identityJson: widget.user.identityJson,
    );
    widget.onUpdate(updatedUser);
    widget.onClose();
    widget.reloadUsers();
  }

  Future<void> _pickAvatar() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(source: ImageSource.gallery, maxWidth: 256, maxHeight: 256);
    if (picked == null) return;

    Uint8List bytes = await picked.readAsBytes();
    // Compress to small size for transmission
    try {
      bytes = await FlutterImageCompress.compressWithList(
        bytes,
        minHeight: 128,
        minWidth: 128,
        quality: 60,
      );
    } catch (_) {}

    setState(() {
      _avatarBase64 = base64Encode(bytes);
    });
  }

  @override
  Widget build(BuildContext context) {
    return PrysmScaffold(
      title: 'Profile',
      leading: PrysmIconButton(icon: PrysmIcons.arrowBack, onPressed: widget.onClose),
      actions: [
        PrysmIconButton(
          icon: PrysmIcons.saveOutlined,
          tooltip: 'Save',
          onPressed: _saveProfile,
        ),
      ],
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    return SingleChildScrollView(
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
                    Stack(
                      children: [
                        GestureDetector(
                          onTap: _pickAvatar,
                          child: ContactAvatar(
                            name: name,
                            radius: 50,
                            avatarBase64: _avatarBase64,
                          ),
                        ),
                        Positioned(
                          bottom: 0,
                          right: 0,
                          child: GestureDetector(
                            onTap: _pickAvatar,
                            child: Container(
                              padding: const EdgeInsets.all(6),
                              decoration: BoxDecoration(
                                color: context.prysmStyle.tokens.accent,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: context.prysmStyle.tokens.background,
                                  width: 3,
                                ),
                              ),
                              child: Icon(
                                PrysmIcons.cameraAlt,
                                color: context.prysmStyle.tokens.onAccent,
                                size: 16,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    Text(
                      name,
                      style: const TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Online',
                      style: TextStyle(
                        color: context.prysmStyle.tokens.accent,
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
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
                      leading: const Icon(PrysmIcons.personOutline),
                      title: 'Display Name',
                      subtitle: name,
                      trailing: const Icon(PrysmIcons.arrowForwardIos, size: 16),
                      onTap: _showEditNameDialog,
                    ),
                    const PrysmDivider(),
                    PrysmListRow(
                      leading: const Icon(PrysmIcons.keyOutlined),
                      title: 'Your ID',
                      subtitleWidget: Text(
                        encodeOnionToBase58(widget.user.id),
                        style: const TextStyle(
                          fontSize: 12,
                          fontFamily: 'monospace',
                        ),
                      ),
                      trailing: PrysmIconButton(
                        icon: PrysmIcons.qrCode,
                        tooltip: 'Show QR Code',
                        onPressed: () => showPrysmIdQrDialog(
                          context,
                          encodeOnionToBase58(widget.user.id),
                        ),
                      ),
                      onTap: () {
                        Clipboard.setData(
                          ClipboardData(
                            text: encodeOnionToBase58(widget.user.id),
                          ),
                        );
                        showPrysmToast(context, 'ID copied to clipboard');
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
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
                      leading: const Icon(PrysmIcons.lock),
                      title: 'Privacy Settings',
                      trailing: const Icon(PrysmIcons.arrowForwardIos, size: 16),
                      onTap: () {
                        Navigator.push(
                          context,
                          PrysmPageRoute(
                            page: PrivacySettingsScreen(
                              onClose: () => Navigator.of(context).pop(),
                            ),
                          ),
                        );
                      },
                    ),
                    const PrysmDivider(),
                    PrysmListRow(
                      leading: const Icon(PrysmIcons.helpOutline),
                      title: 'Help & Support',
                      trailing: const Icon(PrysmIcons.arrowForwardIos, size: 16),
                      onTap: () {},
                    ),
                    const PrysmDivider(),
                    PrysmListRow(
                      leading: const Icon(PrysmIcons.infoOutline),
                      title: 'About',
                      trailing: const Icon(PrysmIcons.arrowForwardIos, size: 16),
                      onTap: () {
                        Navigator.push(
                          context,
                          PrysmPageRoute(
                            page: AboutScreen(
                              onClose: () => Navigator.of(context).pop(),
                            ),
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
    );
  }

  void _showEditNameDialog() {
    final nameController = TextEditingController(text: name);
    showPrysmDialog(
      context: context,
      title: 'Edit Name',
      content: PrysmTextField(
        controller: nameController,
        labelText: 'Display Name',
      ),
      cancelLabel: 'Cancel',
      confirmLabel: 'Save',
      onConfirm: () {
        setState(() {
          name = nameController.text;
        });
        DBHelper.insertOrUpdateUser({
          'name': nameController.text,
          'id': widget.user.id,
        });
        Navigator.pop(context);
      },
    );
  }
}
