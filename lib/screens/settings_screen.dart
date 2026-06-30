// lib/screens/settings_screen.dart
import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:prysm/services/backup_service.dart';
import 'package:prysm/screens/widgets/backup_flow.dart';
import 'package:prysm/screens/onboarding/onboarding_screen.dart';
import 'package:prysm/services/tray_service.dart';
import 'package:prysm/services/battery_saver_service.dart';
import 'package:prysm/services/settings_service.dart';
import 'package:prysm/services/call/linux_audio_settings.dart';
import 'package:prysm_linux_audio/prysm_linux_audio.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:prysm/util/download_location.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/stt_model_manager.dart';
import 'package:prysm/models/unlock_type.dart';
import 'package:prysm/screens/widgets/change_passcode_flow.dart';
import 'privacy_settings_screen.dart';
import 'package:flutter/foundation.dart';

class SettingsScreen extends StatefulWidget {
  final VoidCallback onClose;
  final Function(int) onThemeChanged;
  final dynamic torManager;
  final KeyManager? keyManager;
  final String? onionAddress;

  const SettingsScreen({
    required this.onClose,
    required this.onThemeChanged,
    this.torManager,
    this.keyManager,
    this.onionAddress,
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
  bool _minimizeToTray = true;
  bool _minimizeOnMinimizeButton = false;
  bool _enableRelay = false;
  bool _enableFilePreview = false;
  bool _enableLinkUnfurling = false;
  bool _enableVoiceTranscription = false;
  bool _isDownloadingSttModel = false;
  double _sttModelDownloadProgress = 0;
  String _downloadLocationDisplay = 'Loading...';
  List<LinuxAudioDevice> _linuxInputDevices = const [];
  String? _linuxSelectedDeviceId;
  String _linuxSelectedDeviceLabel = 'System default';
  StreamSubscription<void>? _batterySaverSub;

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _loadDownloadLocationDisplay();
    if (!kIsWeb && Platform.isLinux) {
      unawaited(_loadLinuxInputDevices());
    }
    _batterySaverSub = BatterySaverService.instance.onChanged.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _batterySaverSub?.cancel();
    super.dispose();
  }

  void _loadSettings() {
    setState(() {
      _selectedTheme = settings.themeMode;
      _notificationsEnabled = settings.enableNotifications;
      _minimizeToTray = settings.minimizeToTray;
      _minimizeOnMinimizeButton = settings.minimizeOnMinimizeButton;
      _enableRelay = settings.enableRelay;
      _enableFilePreview = settings.enableFilePreview;
      _enableLinkUnfurling = settings.enableLinkUnfurling;
      _enableVoiceTranscription = settings.enableVoiceTranscription;
    });
  }

  Future<void> _showUnlockMethodPicker() async {
    final km = widget.keyManager;
    if (km == null) return;
    final current = settings.unlockType;
  UnlockType? selected = current;

    final picked = await showModalBottomSheet<UnlockType>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Unlock method',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Switching methods requires setting a new unlock code.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 16),
                    RadioGroup<UnlockType>(
                      groupValue: selected,
                      onChanged: (v) => setModalState(() => selected = v),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          RadioListTile<UnlockType>(
                            title: const Text('6-digit PIN'),
                            value: UnlockType.pin,
                          ),
                          RadioListTile<UnlockType>(
                            title: const Text('Passphrase (12+ characters)'),
                            value: UnlockType.passphrase,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    FilledButton(
                      onPressed: selected == null || selected == current
                          ? null
                          : () => Navigator.pop(ctx, selected),
                      child: const Text('Continue'),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );

    if (picked == null || picked == current || !mounted) return;
    final ok = await runUnlockMethodChange(context, km, picked);
    if (mounted && ok) setState(() {});
  }

  Future<void> _loadDownloadLocationDisplay() async {
    final path = await DownloadLocation.displayPath();
    if (mounted) {
      setState(() => _downloadLocationDisplay = path);
    }
  }

  Future<void> _loadLinuxInputDevices() async {
    try {
      final devices = await PrysmLinuxAudio.listInputDevices();
      final selectedId = await LinuxAudioSettings.getSelectedDeviceId();
      if (!mounted) return;
      setState(() {
        _linuxInputDevices = devices;
        _linuxSelectedDeviceId = selectedId;
        _linuxSelectedDeviceLabel = _labelForLinuxDevice(devices, selectedId);
      });
    } catch (_) {}
  }

  String _labelForLinuxDevice(
    List<LinuxAudioDevice> devices,
    String? selectedId,
  ) {
    if (selectedId == null || selectedId.isEmpty) {
      final defaultDevice = devices.where((d) => d.isDefault).firstOrNull;
      return defaultDevice?.name ?? 'System default';
    }
    for (final device in devices) {
      if (device.id == selectedId) {
        return device.name;
      }
    }
    return selectedId;
  }

  void _showLinuxInputDeviceSheet() {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.settings_input_component_outlined),
              title: const Text('System default'),
              trailing: _linuxSelectedDeviceId == null
                  ? const Icon(Icons.check)
                  : null,
              onTap: () async {
                await LinuxAudioSettings.setSelectedDeviceId(null);
                if (!mounted) return;
                setState(() {
                  _linuxSelectedDeviceId = null;
                  _linuxSelectedDeviceLabel =
                      _labelForLinuxDevice(_linuxInputDevices, null);
                });
                if (ctx.mounted) Navigator.pop(ctx);
              },
            ),
            for (final device in _linuxInputDevices)
              ListTile(
                leading: const Icon(Icons.mic_outlined),
                title: Text(device.name),
                subtitle: device.isDefault
                    ? const Text('Default input')
                    : null,
                trailing: _linuxSelectedDeviceId == device.id
                    ? const Icon(Icons.check)
                    : null,
                onTap: () async {
                  await LinuxAudioSettings.setSelectedDeviceId(device.id);
                  if (!mounted) return;
                  setState(() {
                    _linuxSelectedDeviceId = device.id;
                    _linuxSelectedDeviceLabel = device.name;
                  });
                  if (ctx.mounted) Navigator.pop(ctx);
                },
              ),
          ],
        ),
      ),
    );
  }

  void _showDownloadLocationSheet() {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
                child: Text(
                  _downloadLocationDisplay,
                  style: Theme.of(ctx).textTheme.bodySmall,
                ),
              ),
              ListTile(
                leading: const Icon(Icons.folder_open_outlined),
                title: const Text('Choose folder'),
                onTap: () async {
                  Navigator.pop(ctx);
                  await _pickDownloadLocation();
                },
              ),
              ListTile(
                leading: const Icon(Icons.restore_outlined),
                title: const Text('Use system default'),
                onTap: () async {
                  Navigator.pop(ctx);
                  await settings.clearCustomDownloadPath();
                  await _loadDownloadLocationDisplay();
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Download location reset to default')),
                    );
                  }
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _pickDownloadLocation() async {
    final path = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Choose download folder',
    );
    if (path == null) return;

    final dir = Directory(path);
    if (!await dir.exists()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Selected folder does not exist')),
        );
      }
      return;
    }

    await settings.setCustomDownloadPath(path);
    await _loadDownloadLocationDisplay();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Downloads will be saved to $path')),
      );
    }
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
    await settings.setEnableNotifications(value);
    setState(() => _notificationsEnabled = value);
  }

  void _onMinimizeToTrayToggle(bool value) async {
    await settings.setMinimizeToTray(value);
    await TrayService.instance.applySettings();
    setState(() => _minimizeToTray = value);
  }

  void _onMinimizeOnMinimizeButtonToggle(bool value) async {
    await settings.setMinimizeOnMinimizeButton(value);
    setState(() => _minimizeOnMinimizeButton = value);
  }

  void _onFilePreviewToggle(bool value) async {
    await settings.setEnableFilePreview(value);
    setState(() => _enableFilePreview = value);
  }

  void _onLinkUnfurlingToggle(bool value) async {
    await settings.setEnableLinkUnfurling(value);
    setState(() => _enableLinkUnfurling = value);
  }

  Future<void> _onVoiceTranscriptionToggle(bool value) async {
    if (value) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Enable voice transcription?'),
          content: const Text(
            'Prysm will download an on-device English speech model (~110 MB). '
            'Only English voice messages can be transcribed for now. '
            'Transcripts stay on this device and are never sent to contacts.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Enable'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;

      setState(() {
        _enableVoiceTranscription = true;
        _isDownloadingSttModel = true;
        _sttModelDownloadProgress = 0;
      });
      try {
        await SttModelManager.instance.ensureModelReady(
          onProgress: (progress) {
            if (mounted) {
              setState(() => _sttModelDownloadProgress = progress);
            }
          },
        );
        await settings.setEnableVoiceTranscription(true);
      } catch (e) {
        if (mounted) {
          setState(() {
            _enableVoiceTranscription = false;
            _isDownloadingSttModel = false;
          });
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to download speech model: $e')),
          );
        }
        return;
      }
      if (!mounted) return;
      setState(() {
        _isDownloadingSttModel = false;
        _sttModelDownloadProgress = 1;
      });
      return;
    }

    await settings.setEnableVoiceTranscription(false);
    setState(() => _enableVoiceTranscription = false);
  }

  void _onBatterySavingToggle(bool value) async {
    await BatterySaverService.instance.setUserEnabled(value);
    if (mounted) setState(() {});
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
              if (!context.mounted) return;
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Settings reset to defaults')),
              );
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Reset'),
          ),
        ],
      ),
    );
  }

  void _showBackupDialog() => showCreateBackupDialog(context);

  void _openOnboardingReplay() {
    final onion = widget.onionAddress;
    if (onion == null) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => OnboardingScreen(
          onionAddress: onion,
          torReady: true,
          isReplay: true,
          onComplete: () {},
        ),
      ),
    );
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
        final files = await DownloadLocation.listBackupFiles();
        if (files.isEmpty) {
          final location = await DownloadLocation.displayPath();
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('No backup files found in $location')),
          );
          return;
        }

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
                if (widget.keyManager != null) ...[
                  _buildNavigationTile(
                    'Unlock method',
                    Icons.lock_outline,
                    _showUnlockMethodPicker,
                    subtitle: settings.unlockType == UnlockType.pin
                        ? '6-digit PIN'
                        : 'Passphrase (12+ characters)',
                  ),
                  const Divider(height: 1),
                  _buildNavigationTile(
                    'Change passcode',
                    Icons.pin_outlined,
                    () => runChangePasscodeFlow(context, widget.keyManager!),
                    subtitle: settings.unlockType == UnlockType.pin
                        ? 'Update your unlock PIN without changing your identity'
                        : 'Update your unlock passphrase without changing your identity',
                  ),
                  const Divider(height: 1),
                ],
                _buildNavigationTile(
                  'Advanced Privacy',
                  Icons.privacy_tip_outlined,
                  () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => PrivacySettingsScreen(
                          onClose: () => Navigator.of(context).pop(),
                          keyManager: widget.keyManager,
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
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(ok
                              ? 'New Tor circuit requested'
                              : 'Failed to refresh circuit'),
                          duration: const Duration(seconds: 2),
                        ),
                      );
                  },
                  subtitle: 'Request a new circuit when connections are stuck',
                ),
                if (kDebugMode) ...[
                  _buildSwitchTile(
                    'Enable Relay Server',
                    'COMING SOON, NOT WORKING', //'Use relay for offline message delivery',
                    Icons.cloud_outlined,
                    _enableRelay,
                    (bool value) {
                      return true;
                    }, //_onEnableRelayToggle,
                  ),
                ]
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
                const Divider(height: 1),
                _buildSwitchTile(
                  'Battery saving',
                  BatterySaverService.instance.statusSubtitle,
                  Icons.battery_saver_outlined,
                  BatterySaverService.instance.isActive,
                  _onBatterySavingToggle,
                ),
                if (widget.onionAddress != null) ...[
                  const Divider(height: 1),
                  _buildNavigationTile(
                    'Getting started',
                    Icons.tour_outlined,
                    _openOnboardingReplay,
                    subtitle: 'Replay the setup tour',
                  ),
                ],
                if (!Platform.isAndroid && !Platform.isIOS) ...[
                  const Divider(height: 1),
                  _buildSwitchTile(
                    'Minimize to system tray on close',
                    'Keep Prysm running in the tray when closing the window',
                    Icons.minimize_outlined,
                    _minimizeToTray,
                    _onMinimizeToTrayToggle,
                  ),
                  const Divider(height: 1),
                  _buildSwitchTile(
                    'Minimize to tray when minimizing window',
                    'Hide to tray when clicking the minimize button',
                    Icons.keyboard_arrow_down_outlined,
                    _minimizeOnMinimizeButton,
                    _onMinimizeOnMinimizeButtonToggle,
                  ),
                ],
                if (!kIsWeb && Platform.isLinux) ...[
                  const Divider(height: 1),
                  _buildNavigationTile(
                    'Call microphone',
                    Icons.mic_outlined,
                    _showLinuxInputDeviceSheet,
                    subtitle: _linuxSelectedDeviceLabel,
                  ),
                ],
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
                _buildSwitchTile(
                  'File previews',
                  'Show inline previews for documents, images, and media in chat',
                  Icons.preview_outlined,
                  _enableFilePreview,
                  _onFilePreviewToggle,
                ),
                const Divider(height: 1),
                _buildSwitchTile(
                  'Link previews',
                  'Fetch titles and images for URLs in messages via Tor',
                  Icons.link_outlined,
                  _enableLinkUnfurling,
                  _onLinkUnfurlingToggle,
                ),
                const Divider(height: 1),
                _buildSwitchTile(
                  'Voice transcription',
                  'Transcribe English voice messages on this device. Text stays local and is never sent to contacts.',
                  Icons.subtitles_outlined,
                  _enableVoiceTranscription,
                  _onVoiceTranscriptionToggle,
                ),
                if (_isDownloadingSttModel) ...[
                  const Divider(height: 1),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Downloading speech model…',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        const SizedBox(height: 6),
                        LinearProgressIndicator(
                          value: _sttModelDownloadProgress > 0
                              ? _sttModelDownloadProgress
                              : null,
                        ),
                      ],
                    ),
                  ),
                ],
                const Divider(height: 1),
                _buildNavigationTile(
                  'Download Location',
                  Icons.download_outlined,
                  _showDownloadLocationSheet,
                  subtitle: _downloadLocationDisplay,
                ),
                const Divider(height: 1),
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
