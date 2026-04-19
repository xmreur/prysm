// lib/screens/settings_screen.dart
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:prysm/services/backup_service.dart';
import 'package:prysm/services/settings_service.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'privacy_settings_screen.dart';
import 'data_storage_screen.dart';

class SettingsScreen extends StatefulWidget {
  final VoidCallback onClose;
  final Function(int) onThemeChanged;
  final dynamic torManager;

  const SettingsScreen({
    required this.onClose,
    required this.onThemeChanged,
    this.torManager,
    super.key,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final settings = SettingsService();

  // Local state variables
  int _selectedTheme = 0;
  bool _notificationsEnabled = true;
  bool _showOnlineStatus = true;
  bool _readReceipts = true;
  bool _enableRelay = false;
  String? _relayAddress;
  bool _aggressiveRetry = true;
  int _messageRetentionDays = 30;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  void _loadSettings() {
    setState(() {
      _selectedTheme = settings.themeMode;
      _notificationsEnabled = settings.enableNotifications;
      _showOnlineStatus = settings.showOnlineStatus;
      _readReceipts = settings.sendReadReceipts;
      _enableRelay = settings.enableRelay;
      _relayAddress = settings.personalRelayAddress;
      _aggressiveRetry = settings.aggressiveRetry;
      _messageRetentionDays = settings.messageRetentionDays;
    });
  }

  // Theme selection
  void _onThemeSelected(int themeIndex) async {
    setState(() {
      _selectedTheme = themeIndex;
    });
    await settings.setThemeMode(themeIndex);
    widget.onThemeChanged(themeIndex);
  }

  // Toggle methods
  void _onNotificationToggle(bool value) async {
    setState(() {
      _notificationsEnabled = value;
    });
    await settings.setEnableNotifications(value);
  }

  void _onOnlineStatusToggle(bool value) async {
    setState(() {
      _showOnlineStatus = value;
    });
    await settings.setShowOnlineStatus(value);
  }

  void _onReadReceiptsToggle(bool value) async {
    setState(() {
      _readReceipts = value;
    });
    await settings.setSendReadReceipts(value);
  }

  void _onEnableRelayToggle(bool value) async {
    setState(() {
      _enableRelay = value;
    });
    await settings.setEnableRelay(value);
  }

  void _onAggressiveRetryToggle(bool value) async {
    setState(() {
      _aggressiveRetry = value;
    });
    await settings.setAggressiveRetry(value);
  }

  // Dialog methods
  void _showRelayAddressDialog() {
    final controller = TextEditingController(text: _relayAddress ?? '');

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Relay Server Address'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Enter your Tor hidden service address for message relay:',
              style: TextStyle(fontSize: 14),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              decoration: const InputDecoration(
                hintText: 'example1234567890.onion',
                labelText: 'Relay Address',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.cloud_outlined),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Leave empty to disable relay',
              style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              final address = controller.text.trim();
              setState(() {
                _relayAddress = address.isEmpty ? null : address;
              });
              await settings.setPersonalRelayAddress(
                address.isEmpty ? null : address,
              );
              if (mounted) Navigator.pop(context);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  void _showRetentionDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Message Retention'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [7, 14, 30, 90, 365]
              .map(
                (days) => RadioListTile<int>(
                  title: Text('$days days'),
                  subtitle: Text(_getRetentionDescription(days)),
                  value: days,
                  groupValue: _messageRetentionDays,
                  onChanged: (value) async {
                    setState(() {
                      _messageRetentionDays = value!;
                    });
                    await settings.setMessageRetentionDays(value!);
                    if (mounted) Navigator.pop(context);
                  },
                ),
              )
              .toList(),
        ),
      ),
    );
  }

  String _getRetentionDescription(int days) {
    if (days == 7) return 'Minimal storage';
    if (days == 14) return 'Short term';
    if (days == 30) return 'Default';
    if (days == 90) return 'Extended';
    return 'Long term';
  }

  void _showAboutDialog() {
    showAboutDialog(
      context: context,
      applicationName: settings.name,
      applicationVersion: settings.version,
      applicationIcon: const Icon(Icons.privacy_tip, size: 48),
      children: [
        Text(settings.description),
        const SizedBox(height: 16),
        const Text('Features:'),
        const Text('• End-to-end encryption'),
        const Text('• Tor network routing'),
        const Text('• No central servers'),
        const Text('• Open source'),
      ],
    );
  }

  void _showResetDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reset All Settings?'),
        content: const Text(
          'This will restore all settings to their default values. This action cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              await settings.reset();
              _loadSettings();
              widget.onThemeChanged(0); // Reset to light theme
              if (mounted) {
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Settings reset to defaults')),
                );
              }
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Reset'),
          ),
        ],
      ),
    );
  }

  void _showBackupDialog() {
    final passwordController = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Create Backup'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Choose a strong password to encrypt your backup. You will need this password to restore.',
              style: TextStyle(fontSize: 14),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: passwordController,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Backup Password',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.lock_outline),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              final password = passwordController.text;
              if (password.length < 4) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Password must be at least 4 characters')),
                );
                return;
              }
              Navigator.pop(context);
              await _performBackup(password);
            },
            child: const Text('Create Backup'),
          ),
        ],
      ),
    );
  }

  Future<void> _performBackup(String password) async {
    try {
      // Save to Documents/prysm_backups/ on all platforms to avoid
      // freedesktop portal issues on Linux desktop.
      final dir = await getApplicationDocumentsDirectory();
      final backupDir = Directory(p.join(dir.path, 'prysm_backups'));
      if (!await backupDir.exists()) await backupDir.create(recursive: true);
      final fileName = 'prysm_backup_${DateTime.now().millisecondsSinceEpoch}.prysmbackup';
      final outputPath = p.join(backupDir.path, fileName);
      await BackupService.createBackup(outputPath, password);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Backup saved to ${backupDir.path}/$fileName'),
            duration: const Duration(seconds: 5),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Backup failed: $e')),
        );
      }
    }
  }

  void _showRestoreDialog() {
    final passwordController = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Restore Backup'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'This will replace all current data with the backup. The app will restart after restore.',
              style: TextStyle(fontSize: 14, color: Colors.red),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: passwordController,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Backup Password',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.lock_outline),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              final password = passwordController.text;
              Navigator.pop(context);
              await _performRestore(password);
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Restore'),
          ),
        ],
      ),
    );
  }

  Future<void> _performRestore(String password) async {
    try {
      String? filePath;

      if (Platform.isAndroid || Platform.isIOS) {
        final result = await FilePicker.platform.pickFiles(
          dialogTitle: 'Select Backup File',
          type: FileType.any,
        );
        if (result == null || result.files.single.path == null) return;
        filePath = result.files.single.path!;
      } else {
        // Desktop: list backups from the known backup directory
        final dir = await getApplicationDocumentsDirectory();
        final backupDir = Directory(p.join(dir.path, 'prysm_backups'));
        if (!await backupDir.exists()) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('No backups found in ${backupDir.path}')),
            );
          }
          return;
        }
        final files = await backupDir
            .list()
            .where((e) => e is File && e.path.endsWith('.prysmbackup'))
            .cast<File>()
            .toList();
        if (files.isEmpty) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('No backup files found in ${backupDir.path}')),
            );
          }
          return;
        }
        // Sort newest first
        files.sort((a, b) => b.path.compareTo(a.path));

        if (!mounted) return;
        final chosen = await showDialog<File>(
          context: context,
          builder: (context) => SimpleDialog(
            title: const Text('Select Backup'),
            children: files.map((f) => SimpleDialogOption(
              onPressed: () => Navigator.pop(context, f),
              child: Text(p.basename(f.path), style: const TextStyle(fontSize: 14)),
            )).toList(),
          ),
        );
        if (chosen == null) return;
        filePath = chosen.path;
      }

      final ok = await BackupService.restoreBackup(filePath, password);
      if (mounted) {
        if (ok) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Backup restored! Please restart the app.')),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Restore failed — wrong password or corrupt file')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Restore failed: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 70,
        title: const Text(
          'Settings',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: widget.onClose,
        ),
        elevation: 2,
        shadowColor: Colors.black.withValues(alpha: 0.1),
      ),
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ==================== APPEARANCE ====================
              _buildSectionHeader('Appearance'),
              const SizedBox(height: 12),
              _buildCard([
                _buildThemeOption('Light Mode', Icons.light_mode_outlined, 0),
                const Divider(height: 1),
                _buildThemeOption('Dark Mode', Icons.dark_mode_outlined, 1),
                const Divider(height: 1),
                _buildThemeOption('Pink Mode', Icons.auto_awesome_outlined, 2),
                const Divider(height: 1),
                _buildThemeOption('Cyan Mode', Icons.water_drop_outlined, 3),
                const Divider(height: 1),
                _buildThemeOption(
                  'Purple Mode',
                  Icons.auto_fix_high_outlined,
                  4,
                ),
                const Divider(height: 1),
                _buildThemeOption('Orange Mode', Icons.whatshot_outlined, 5),
              ]),

              const SizedBox(height: 30),

              // ==================== PRIVACY ====================
              _buildSectionHeader('Privacy'),
              const SizedBox(height: 12),
              _buildCard([
                // _buildSwitchTile(
                //   'Show Online Status',
                //   'Let others see when you\'re online',
                //   Icons.circle_outlined,
                //   _showOnlineStatus,
                //   _onOnlineStatusToggle,
                // ),
                // const Divider(height: 1),
                // _buildSwitchTile(
                //   'Read Receipts',
                //   'Let others know when you read messages',
                //   Icons.done_all_outlined,
                //   _readReceipts,
                //   _onReadReceiptsToggle,
                // ),
                // const Divider(height: 1),
                _buildNavigationTile(
                  'Advanced Privacy',
                  Icons.privacy_tip_outlined,
                  () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => PrivacySettingsScreen(
                          onClose: () => Navigator.of(context).pop(),
                        ),
                      ),
                    );
                  },
                ),
              ]),

              const SizedBox(height: 30),

              // ==================== NETWORK ====================
              _buildSectionHeader('Network'),
              const SizedBox(height: 12),
              _buildCard([
                _buildNavigationTile(
                  'Refresh Tor Circuit',
                  Icons.sync,
                  () async {
                    if (widget.torManager == null) return;
                    final ok = await widget.torManager.refreshCircuit();
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(ok
                              ? 'New Tor circuit requested'
                              : 'Failed to refresh circuit'),
                          duration: const Duration(seconds: 2),
                        ),
                      );
                    }
                  },
                  subtitle: 'Request a new circuit when connections are stuck',
                ),
                const Divider(height: 1),
                _buildSwitchTile(
                  'Enable Relay Server',
                  'COMING SOON, NOT WORKING', //'Use relay for offline message delivery',
                  Icons.cloud_outlined,
                  _enableRelay,
                  (bool value) {
                    return true;
                  }, //_onEnableRelayToggle,
                ),
                // if (_enableRelay) ...[
                //   const Divider(height: 1),
                //   _buildNavigationTile(
                //     'Relay Address',
                //     Icons.dns_outlined,
                //     _showRelayAddressDialog,
                //     subtitle: _relayAddress ?? 'Not configured',
                //   ),
                // ],
                // const Divider(height: 1),
                // _buildSwitchTile(
                //   'Aggressive Retry',
                //   'Retry sending messages more frequently',
                //   Icons.refresh_outlined,
                //   _aggressiveRetry,
                //   _onAggressiveRetryToggle,
                // ),
              ]),

              const SizedBox(height: 30),

              // ==================== GENERAL ====================
              _buildSectionHeader('General'),
              const SizedBox(height: 12),
              _buildCard([
                _buildSwitchTile(
                  'Notifications',
                  'Show notifications for new messages',
                  Icons.notifications_outlined,
                  _notificationsEnabled,
                  _onNotificationToggle,
                ),
                // const Divider(height: 1),
                // _buildNavigationTile(
                //   'Data & Storage',
                //   Icons.storage_outlined,
                //   () {
                //     Navigator.push(
                //       context,
                //       MaterialPageRoute(
                //         builder: (context) => DataStorageScreen(
                //           onClose: () => Navigator.of(context).pop(),
                //         ),
                //       ),
                //     );
                //   },
                // ),
                // const Divider(height: 1),
                // _buildNavigationTile(
                //   'Message Retention',
                //   Icons.delete_sweep_outlined,
                //   _showRetentionDialog,
                //   subtitle: '$_messageRetentionDays days',
                // ),
              ]),

              const SizedBox(height: 30),

              // ==================== DATA ====================
              _buildSectionHeader('Data'),
              const SizedBox(height: 12),
              _buildCard([
                _buildNavigationTile(
                  'Create Backup',
                  Icons.backup_outlined,
                  _showBackupDialog,
                  subtitle: 'Export encrypted backup file',
                ),
                const Divider(height: 1),
                _buildNavigationTile(
                  'Restore Backup',
                  Icons.restore_outlined,
                  _showRestoreDialog,
                  subtitle: 'Import from backup file',
                ),
              ]),

              const SizedBox(height: 30),

              // ==================== ABOUT ====================
              _buildSectionHeader('About'),
              const SizedBox(height: 12),
              _buildCard([
                _buildNavigationTile(
                  'About ${settings.name}',
                  Icons.info_outlined,
                  _showAboutDialog,
                  subtitle: 'Version ${settings.version}',
                ),
                const Divider(height: 1),
                _buildNavigationTile(
                  'Source Code',
                  Icons.code_outlined,
                  () async {
                    await launchUrl(
                      Uri.parse('https://github.com/xmreur/prysm'),
                      mode: LaunchMode.externalApplication,
                    );
                  },
                  subtitle: 'View on GitHub',
                ),
              ]),

              const SizedBox(height: 30),

              // ==================== DANGER ZONE ====================
              _buildSectionHeader('Danger Zone', color: Colors.red),
              const SizedBox(height: 12),
              _buildCard([
                _buildNavigationTile(
                  'Reset Settings',
                  Icons.restore_outlined,
                  _showResetDialog,
                  subtitle: 'Restore default settings',
                  textColor: Colors.red,
                ),
              ]),

              const SizedBox(height: 30),
            ],
          ),
        ),
      ),
    );
  }

  // ==================== WIDGET BUILDERS ====================

  Widget _buildSectionHeader(String title, {Color? color}) {
    return Text(
      title,
      style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: color),
    );
  }

  Widget _buildCard(List<Widget> children) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: children),
    );
  }

  Widget _buildThemeOption(String title, IconData icon, int themeIndex) {
    final bool isSelected = _selectedTheme == themeIndex;

    Color getTextColor() {
      if (isSelected) {
        switch (themeIndex) {
          case 0:
            return Colors.teal;
          case 1:
            return Colors.white;
          case 2:
            return Colors.pink;
          case 3:
            return Colors.cyan;
          case 4:
            return Colors.purple;
          case 5:
            return Colors.orange;
          default:
            return Theme.of(context).primaryColor;
        }
      } else {
        return Theme.of(context).brightness == Brightness.dark
            ? Colors.white
            : Colors.black87;
      }
    }

    return ListTile(
      leading: Icon(
        icon,
        color: isSelected ? getTextColor() : Theme.of(context).iconTheme.color,
      ),
      title: Text(
        title,
        style: TextStyle(
          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
          color: getTextColor(),
        ),
      ),
      trailing: Container(
        width: 24,
        height: 24,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: isSelected ? getTextColor() : Theme.of(context).dividerColor,
            width: 2,
          ),
          color: isSelected ? getTextColor() : Colors.transparent,
        ),
        child: isSelected
            ? Icon(
                Icons.check,
                size: 16,
                color: (themeIndex == 1 || themeIndex == 4 || themeIndex == 5)
                    ? Colors.black87
                    : Colors.white,
              )
            : null,
      ),
      onTap: () => _onThemeSelected(themeIndex),
    );
  }

  Widget _buildSwitchTile(
    String title,
    String subtitle,
    IconData icon,
    bool value,
    Function(bool) onChanged,
  ) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(
        subtitle,
        style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor),
      ),
      trailing: Switch(
        value: value,
        onChanged: onChanged,
      ),
      onTap: () => onChanged(!value),
    );
  }

  Widget _buildNavigationTile(
    String title,
    IconData icon,
    VoidCallback onTap, {
    String? subtitle,
    Color? textColor,
  }) {
    return ListTile(
      leading: Icon(icon, color: textColor),
      title: Text(title, style: TextStyle(color: textColor)),
      subtitle: subtitle != null
          ? Text(
              subtitle,
              style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor),
            )
          : null,
      trailing: Icon(Icons.arrow_forward_ios, size: 16, color: textColor),
      onTap: onTap,
    );
  }
}
