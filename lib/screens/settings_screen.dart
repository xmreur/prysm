import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'privacy_settings_screen.dart';
import 'data_storage_screen.dart';

class SettingsScreen extends StatefulWidget {
  final VoidCallback onClose;
  final Function(int) onThemeChanged;

  const SettingsScreen({
    required this.onClose,
    required this.onThemeChanged,
    super.key,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  int _selectedTheme =
      0; // 0: Light, 1: Dark, 2: Pink, 3: Cyan, 4: Purple, 5: Orange
  bool _notificationsEnabled = true;
  bool _showOnlineStatus = true;
  bool _readReceipts = true;

  @override
  void initState() {
    super.initState();
    _loadSavedTheme();
    _loadPrivacySettings();
  }

  Future<void> _loadSavedTheme() async {
    final prefs = await SharedPreferences.getInstance();
    final themeIndex = prefs.getInt('custom_theme') ?? 0;
    setState(() {
      _selectedTheme = themeIndex;
    });
  }

  Future<void> _loadPrivacySettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _notificationsEnabled = prefs.getBool('notifications_enabled') ?? true;
      _showOnlineStatus = prefs.getBool('show_online_status') ?? true;
      _readReceipts = prefs.getBool('read_receipts') ?? true;
    });
  }

  Future<void> _saveTheme(int themeIndex) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('custom_theme', themeIndex);
  }

  Future<void> _savePrivacySetting(String key, bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(key, value);
  }

  void _onThemeSelected(int themeIndex) {
    setState(() {
      _selectedTheme = themeIndex;
    });
    _saveTheme(themeIndex);
    widget.onThemeChanged(themeIndex);
  }

  void _onNotificationToggle(bool value) {
    setState(() {
      _notificationsEnabled = value;
    });
    _savePrivacySetting('notifications_enabled', value);
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
              const Text(
                'Appearance',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 20),
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
                    _buildThemeOption(
                      context,
                      'Light Mode',
                      Icons.light_mode_outlined,
                      0,
                    ),
                    const Divider(height: 1),
                    _buildThemeOption(
                      context,
                      'Dark Mode',
                      Icons.dark_mode_outlined,
                      1,
                    ),
                    const Divider(height: 1),
                    _buildThemeOption(
                      context,
                      'Pink Mode',
                      Icons.auto_awesome_outlined,
                      2,
                    ),
                    const Divider(height: 1),
                    _buildThemeOption(
                      context,
                      'Cyan Mode',
                      Icons.water_drop_outlined,
                      3,
                    ),
                    const Divider(height: 1),
                    _buildThemeOption(
                      context,
                      'Purple Mode',
                      Icons.auto_fix_high_outlined,
                      4,
                    ),
                    const Divider(height: 1),
                    _buildThemeOption(
                      context,
                      'Orange Mode',
                      Icons.whatshot_outlined,
                      5,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 30),
              const Text(
                'Privacy',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 20),
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
                    _buildSettingOption(
                      context,
                      'Privacy Settings',
                      Icons.privacy_tip_outlined,
                      false,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 30),
              const Text(
                'General',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 20),
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
                    _buildSettingOptionWithSwitch(
                      context,
                      'Notifications',
                      Icons.notifications_outlined,
                      _notificationsEnabled,
                      _onNotificationToggle,
                    ),
                    const Divider(height: 1),
                    _buildSettingOption(
                      context,
                      'Data & Storage',
                      Icons.storage_outlined,
                      false,
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

  Widget _buildThemeOption(
    BuildContext context,
    String title,
    IconData icon,
    int themeIndex,
  ) {
    final bool isSelected = _selectedTheme == themeIndex;

    // Define text colors for each theme
    Color getTextColor() {
      if (isSelected) {
        // For selected themes, use theme-appropriate colors
        switch (themeIndex) {
          case 0: // Light Mode
            return Colors.teal; // Teal for light mode
          case 1: // Dark Mode
            return Colors.white; // White for dark mode
          case 2: // Pink Mode
            return Colors.pink; // Pink for pink mode
          case 3: // Cyan Mode
            return Colors.cyan; // Cyan for cyan mode
          case 4: // Purple Mode
            return Colors.purple; // Purple for purple mode
          case 5: // Orange Mode
            return Colors.orange; // Orange for orange mode
          default:
            return Theme.of(context).primaryColor;
        }
      } else {
        // For unselected themes, use theme-appropriate colors based on current theme
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
              ) // Black checkmark for dark themes
            : null,
      ),
      onTap: () => _onThemeSelected(themeIndex),
    );
  }

  Widget _buildSettingOption(
    BuildContext context,
    String title,
    IconData icon,
    bool hasSwitch,
  ) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      trailing: hasSwitch
          ? Container(
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                color: Theme.of(context).brightness == Brightness.dark
                    ? Colors.white.withValues(alpha: 0.1)
                    : Colors.black.withValues(alpha: 0.05),
              ),
              child: Switch(
                value: true,
                onChanged: (value) {},
                activeThumbColor: Colors.white,
                activeTrackColor: Theme.of(context).primaryColor,
                inactiveThumbColor: Colors.white,
                inactiveTrackColor:
                    Theme.of(context).brightness == Brightness.dark
                    ? Colors.grey[700]
                    : Colors.grey[400],
              ),
            )
          : const Icon(Icons.arrow_forward_ios, size: 16),
      onTap: () {
        if (title == 'Privacy Settings') {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => PrivacySettingsScreen(
                onClose: () => Navigator.of(context).pop(),
              ),
            ),
          );
        } else if (title == 'Data & Storage') {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) =>
                  DataStorageScreen(onClose: () => Navigator.of(context).pop()),
            ),
          );
        }
      },
    );
  }

  Widget _buildSettingOptionWithSwitch(
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
