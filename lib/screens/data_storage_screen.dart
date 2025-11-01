import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class DataStorageScreen extends StatefulWidget {
  final VoidCallback onClose;

  const DataStorageScreen({required this.onClose, super.key});

  @override
  State<DataStorageScreen> createState() => _DataStorageScreenState();
}

class _DataStorageScreenState extends State<DataStorageScreen> {
  bool _autoDownloadMedia = true;
  bool _keepMedia = true;
  bool _autoDeleteMessages = false;
  final int _storageUsage = 128; // in MB
  //int _cacheSize = 45; // in MB

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
    setState(() {
      _autoDownloadMedia = value;
    });
    _saveDataStorageSetting('auto_download_media', value);
  }

  void _onKeepMediaToggle(bool value) {
    setState(() {
      _keepMedia = value;
    });
    _saveDataStorageSetting('keep_media', value);
  }

  void _onAutoDeleteMessagesToggle(bool value) {
    setState(() {
      _autoDeleteMessages = value;
    });
    _saveDataStorageSetting('auto_delete_messages', value);
  }

  void _onClearChatHistory() {
    // Show confirmation dialog
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Clear Chat History'),
          content: const Text(
            'Are you sure you want to clear all chat history? This cannot be undone.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
                // In a real app, this would clear the actual chat history
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Chat history cleared')),
                );
              },
              child: const Text('Clear', style: TextStyle(color: Colors.red)),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 70,
        title: const Text(
          'Data & Storage',
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
                    _buildStorageOption(
                      context,
                      'Auto-download Media',
                      Icons.download_outlined,
                      _autoDownloadMedia,
                      _onAutoDownloadMediaToggle,
                      'Automatically download photos, videos, and documents',
                    ),
                    const Divider(height: 1),
                    _buildStorageOption(
                      context,
                      'Keep Media',
                      Icons.image_outlined,
                      _keepMedia,
                      _onKeepMediaToggle,
                      'Store media files on your device',
                    ),
                    const Divider(height: 1),
                    _buildStorageOption(
                      context,
                      'Auto-delete Messages',
                      Icons.delete_outlined,
                      _autoDeleteMessages,
                      _onAutoDeleteMessagesToggle,
                      'Automatically delete old messages to save space',
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 30),
              const Text(
                'Storage Usage',
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
                    ListTile(
                      leading: const Icon(Icons.storage_outlined),
                      title: const Text('Total Storage'),
                      subtitle: Text('$_storageUsage MB used'),
                      trailing: const Icon(Icons.arrow_forward_ios, size: 16),
                    ),
                    const Divider(height: 1),
                  ],
                ),
              ),
              const SizedBox(height: 30),
              const Text(
                'Manage Data',
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
                    ListTile(
                      leading: const Icon(Icons.delete_outline),
                      title: const Text('Clear Chat History'),
                      subtitle: const Text(
                        'Delete all messages from all chats',
                      ),
                      trailing: ElevatedButton(
                        onPressed: _onClearChatHistory,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Theme.of(context).colorScheme.error,
                          foregroundColor: Colors.white,
                        ),
                        child: const Text('Clear'),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 30),
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
                child: const Text(
                  'Manage your data usage and storage preferences. '
                  'These settings help you control how Prysm uses your device storage.',
                  style: TextStyle(fontSize: 16),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStorageOption(
    BuildContext context,
    String title,
    IconData icon,
    bool value,
    Function(bool) onChanged,
    String subtitle,
  ) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(subtitle),
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
