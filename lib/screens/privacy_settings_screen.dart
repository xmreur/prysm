import 'package:flutter/material.dart';
import 'package:prysm/screens/panic_pin_settings_screen.dart';
import 'package:prysm/services/panic_pin_service.dart';
import 'package:prysm/services/settings_service.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

class PrivacySettingsScreen extends StatefulWidget {
  final VoidCallback onClose;
  final KeyManager? keyManager;

  const PrivacySettingsScreen({
    required this.onClose,
    this.keyManager,
    super.key,
  });

  @override
  State<PrivacySettingsScreen> createState() => _PrivacySettingsScreenState();
}

class _PrivacySettingsScreenState extends State<PrivacySettingsScreen> {
  static final settings = SettingsService();

  bool _showOnlineStatus = true;
  bool _readReceipts = true;
  bool _lastSeen = true;
  bool _profilePhoto = true;

  @override
  void initState() {
    super.initState();
    _loadPrivacySettings();
  }

  Future<void> _loadPrivacySettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _showOnlineStatus = prefs.getBool('show_online_status') ?? true;
      _readReceipts = settings.sendReadReceipts;
      _lastSeen = prefs.getBool('last_seen') ?? true;
      _profilePhoto = prefs.getBool('profile_photo') ?? true;
    });
  }

  Future<void> _savePrivacySetting(String key, bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(key, value);
  }

  void _onOnlineStatusToggle(bool value) {
    setState(() {
      _showOnlineStatus = value;
    });
    _savePrivacySetting('show_online_status', value);
    settings.setShowOnlineStatus(value);
  }

  Future<void> _onReadReceiptsToggle(bool value) async {
    setState(() {
      _readReceipts = value;
    });
    await settings.setSendReadReceipts(value);
  }

  void _onLastSeenToggle(bool value) {
    setState(() {
      _lastSeen = value;
    });
    _savePrivacySetting('last_seen', value);
  }

  void _onProfilePhotoToggle(bool value) {
    setState(() {
      _profilePhoto = value;
    });
    _savePrivacySetting('profile_photo', value);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 70,
        title: const Text(
          'Privacy Settings',
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
              Container(
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
                child: Column(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.visibility_outlined),
                      title: const Text('Show Online Status'),
                      subtitle: const Text(
                        'When enabled, recent contacts are notified when you come online so they can deliver pending messages faster.',
                      ),
                      trailing: Container(
                        padding: const EdgeInsets.all(2),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          color: Theme.of(context).brightness == Brightness.dark
                              ? Colors.white.withValues(alpha: 0.1)
                              : Colors.black.withValues(alpha: 0.05),
                        ),
                        child: Switch(
                          value: _showOnlineStatus,
                          onChanged: _onOnlineStatusToggle,
                          activeThumbColor: Colors.white,
                          activeTrackColor: Theme.of(context).primaryColor,
                          inactiveThumbColor: Colors.white,
                          inactiveTrackColor:
                              Theme.of(context).brightness == Brightness.dark
                                  ? Colors.grey[700]
                                  : Colors.grey[400],
                        ),
                      ),
                      onTap: () => _onOnlineStatusToggle(!_showOnlineStatus),
                    ),
                    const Divider(height: 1),
                    _buildPrivacyOption(
                      context,
                      'Read Receipts',
                      Icons.check_circle_outline_outlined,
                      _readReceipts,
                      _onReadReceiptsToggle,
                    ),
                    const Divider(height: 1),
                    _buildPrivacyOption(
                      context,
                      'Last Seen',
                      Icons.access_time_outlined,
                      _lastSeen,
                      _onLastSeenToggle,
                    ),
                    const Divider(height: 1),
                    _buildPrivacyOption(
                      context,
                      'Profile Photo',
                      Icons.account_circle_outlined,
                      _profilePhoto,
                      _onProfilePhotoToggle,
                    ),
                  ],
                ),
              ),
              if (widget.keyManager != null) ...[
                const SizedBox(height: 30),
                const Text(
                  'Emergency',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                Container(
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
                  child: ListTile(
                    leading: const Icon(Icons.emergency_outlined),
                    title: const Text('Panic mode'),
                    subtitle: FutureBuilder<bool>(
                      future: PanicPinService.instance.isConfigured(),
                      builder: (context, snapshot) {
                        final configured = snapshot.data == true;
                        return Text(
                          configured
                              ? 'Panic PIN configured'
                              : 'Set a secondary panic PIN',
                        );
                      },
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => PanicPinSettingsScreen(
                            keyManager: widget.keyManager!,
                            onClose: () => Navigator.pop(context),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
              const SizedBox(height: 30),
              const Text(
                'Privacy Information',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 20),
              Container(
                padding: const EdgeInsets.all(16),
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
                child: Text(
                  'These settings help you control your privacy on ${settings.name}. '
                  'Your choices will be applied across all your conversations.',
                  style: const TextStyle(fontSize: 16),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPrivacyOption(
    BuildContext context,
    String title,
    IconData icon,
    bool value,
    Function(bool) onChanged,
  ) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      trailing: Container(
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: Theme.of(context).brightness == Brightness.dark
              ? Colors.white.withValues(alpha: 0.1)
              : Colors.black.withValues(alpha: 0.05),
        ),
        child: Switch(
          value: value,
          onChanged: onChanged,
          activeThumbColor: Colors.white,
          activeTrackColor: Theme.of(context).primaryColor,
          inactiveThumbColor: Colors.white,
          inactiveTrackColor: Theme.of(context).brightness == Brightness.dark
              ? Colors.grey[700]
              : Colors.grey[400],
        ),
      ),
      onTap: () {
        onChanged(!value);
      },
    );
  }
}
