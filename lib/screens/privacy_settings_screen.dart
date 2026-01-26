import 'package:flutter/material.dart';
import 'package:prysm/services/settings_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class PrivacySettingsScreen extends StatefulWidget {
  final VoidCallback onClose;

  const PrivacySettingsScreen({required this.onClose, super.key});

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
      _readReceipts = prefs.getBool('read_receipts') ?? true;
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
  }

  void _onReadReceiptsToggle(bool value) {
    setState(() {
      _readReceipts = value;
    });
    _savePrivacySetting('read_receipts', value);
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
                    _buildPrivacyOption(
                      context,
                      'Show Online Status',
                      Icons.visibility_outlined,
                      _showOnlineStatus,
                      _onOnlineStatusToggle,
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
