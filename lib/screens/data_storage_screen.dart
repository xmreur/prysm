import 'package:flutter/widgets.dart';
import 'package:prysm/ui/core/prysm_icons.dart';
import 'package:prysm/ui/core/prysm_toast.dart';
import 'package:prysm/ui/core/prysm_list_row.dart';
import 'package:prysm/ui/core/prysm_dialog.dart';
import 'package:prysm/theme/prysm_style_scope.dart';
import 'package:prysm/theme/prysm_tokens.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:prysm/services/settings_service.dart';
import 'package:prysm/ui/core/prysm_button.dart';
import 'package:prysm/ui/core/prysm_switch.dart';
import 'package:prysm/ui/prysm_scaffold.dart';
import 'package:prysm/ui/prysm_section.dart';

class DataStorageScreen extends StatefulWidget {
  final VoidCallback onClose;

  const DataStorageScreen({required this.onClose, super.key});
  @override
  State<DataStorageScreen> createState() => _DataStorageScreenState();
}

class _DataStorageScreenState extends State<DataStorageScreen> {
  static final settings = SettingsService();
  bool _autoDownloadMedia = true;
  bool _keepMedia = true;
  bool _autoDeleteMessages = false;
  final int _storageUsage = 128;

  @override
  void initState() {
    super.initState();
    _loadDataStorageSettings();
  }

  Future<void> _loadDataStorageSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _autoDownloadMedia = prefs.getBool('auto_download_media') ?? true;
      _keepMedia = prefs.getBool('keep_media') ?? true;
      _autoDeleteMessages = prefs.getBool('auto_delete_messages') ?? false;
    });
  }

  Future<void> _saveDataStorageSetting(String key, bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(key, value);
  }

  void _onAutoDownloadMediaToggle(bool value) {
    setState(() => _autoDownloadMedia = value);
    _saveDataStorageSetting('auto_download_media', value);
  }

  void _onKeepMediaToggle(bool value) {
    setState(() => _keepMedia = value);
    _saveDataStorageSetting('keep_media', value);
  }

  void _onAutoDeleteMessagesToggle(bool value) {
    setState(() => _autoDeleteMessages = value);
    _saveDataStorageSetting('auto_delete_messages', value);
  }

  Future<void> _onClearChatHistory() async {
    final confirmed = await showPrysmConfirmDialog(
      context: context,
      title: 'Clear Chat History',
      content: const Text(
        'Are you sure you want to clear all chat history? This cannot be undone.',
      ),
      cancelLabel: 'Cancel',
      confirmLabel: 'Clear',
      confirmVariant: PrysmButtonVariant.danger,
    );
    if (confirmed == true && mounted) {
      showPrysmToast(context, 'Chat history cleared');
    }
  }

  @override
  Widget build(BuildContext context) {
    final style = context.prysmStyle;
    return PrysmPage(
      title: 'Data & Storage',
      headerHeight: 70,
      leading: PrysmIconButton(
        icon: PrysmIcons.arrowBack,
        onPressed: widget.onClose,
      ),
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(PrysmTokens.spacing16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              PrysmSection(
                children: [
                  PrysmSwitchRow(
                    title: 'Auto-download Media',
                    subtitle:
                        'Automatically download photos, videos, and documents',
                    value: _autoDownloadMedia,
                    onChanged: _onAutoDownloadMediaToggle,
                  ),
                  PrysmSwitchRow(
                    title: 'Keep Media',
                    subtitle: 'Store media files on your device',
                    value: _keepMedia,
                    onChanged: _onKeepMediaToggle,
                  ),
                  PrysmSwitchRow(
                    title: 'Auto-delete Messages',
                    subtitle:
                        'Automatically delete old messages to save space',
                    value: _autoDeleteMessages,
                    onChanged: _onAutoDeleteMessagesToggle,
                  ),
                ],
              ),
              const SizedBox(height: 30),
              Text('Storage Usage', style: style.headlineStyle),
              const SizedBox(height: 20),
              PrysmSection(
                children: [
                  PrysmListRow(
                    leading: const Icon(PrysmIcons.storageOutlined),
                    title: 'Total Storage',
                    subtitle: '$_storageUsage MB used',
                    trailing:
                        const Icon(PrysmIcons.arrowForwardIos, size: 16),
                  ),
                ],
              ),
              const SizedBox(height: 30),
              Text('Manage Data', style: style.headlineStyle),
              const SizedBox(height: 20),
              PrysmSection(
                children: [
                  PrysmListRow(
                    leading: const Icon(PrysmIcons.deleteOutline),
                    title: 'Clear Chat History',
                    subtitle: 'Delete all messages from all chats',
                    trailing: PrysmButton(
                      label: 'Clear',
                      variant: PrysmButtonVariant.danger,
                      onPressed: _onClearChatHistory,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 30),
              Container(
                padding: const EdgeInsets.all(PrysmTokens.spacing16),
                decoration: BoxDecoration(
                  color: style.tokens.surface,
                  borderRadius:
                      BorderRadius.circular(PrysmTokens.radiusCard),
                ),
                child: Text(
                  'Manage your data usage and storage preferences. '
                  'These settings help you control how ${settings.name} uses your device storage.',
                  style: style.bodyStyle,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
