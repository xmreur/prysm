// lib/screens/settings_screen.dart
import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
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
import 'package:prysm/services/biometric_unlock_service.dart';
import 'package:prysm/screens/widgets/change_passcode_flow.dart';
import 'privacy_settings_screen.dart';
import 'blocked_contacts_screen.dart';
import 'package:prysm/screens/widgets/appearance_settings_section.dart';
import 'package:prysm/theme/prysm_theme.dart';
import 'package:prysm/theme/prysm_themes.dart';
import 'package:prysm/ui/prysm_scaffold.dart';

import 'package:flutter/widgets.dart';
import 'package:prysm/ui/core/prysm_icons.dart';
import 'package:prysm/ui/core/prysm_app.dart';
import 'package:prysm/ui/core/prysm_toast.dart';
import 'package:prysm/theme/prysm_style_scope.dart';
import 'package:prysm/ui/core/prysm_linear_progress.dart';
import 'package:prysm/ui/core/prysm_button.dart';
import 'package:prysm/ui/core/prysm_switch.dart';
import 'package:prysm/ui/core/prysm_list_row.dart';
import 'package:prysm/ui/core/prysm_divider.dart';
import 'package:prysm/ui/core/prysm_dialog.dart';
import 'package:prysm/ui/core/prysm_radio.dart';
import 'package:prysm/ui/core/prysm_text_field.dart';
class SettingsScreen extends StatefulWidget {
  final VoidCallback onClose;
  final Function(int) onThemeChanged;
  final VoidCallback? onAppearanceChanged;
  final dynamic torManager;
  final KeyManager? keyManager;
  final String? onionAddress;
  final bool offlineMode;
  final bool torConnecting;
  final Future<void> Function()? onConnectTor;

  const SettingsScreen({
    required this.onClose,
    required this.onThemeChanged,
    this.onAppearanceChanged,
    this.torManager,
    this.keyManager,
    this.onionAddress,
    this.offlineMode = false,
    this.torConnecting = false,
    this.onConnectTor,
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
  bool _biometricsEnabled = false;
  bool _biometricsAvailable = false;
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
    if (Platform.isAndroid) {
      unawaited(_loadBiometricsState());
    }
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
      _biometricsEnabled = settings.biometricsEnabled;
    });
  }

  Future<void> _loadBiometricsState() async {
    final available = await BiometricUnlockService.instance.isAvailable();
    if (mounted) {
      setState(() => _biometricsAvailable = available);
    }
  }

  Future<void> _onBiometricsToggled(bool value) async {
    final km = widget.keyManager;
    if (km == null) return;

    if (!value) {
      await BiometricUnlockService.instance.clear();
      await settings.setBiometricsEnabled(false);
      if (mounted) setState(() => _biometricsEnabled = false);
      return;
    }

    final current = await promptCurrentUnlockSecret(
      context,
      km,
      settings.unlockType,
    );
    if (current == null || !mounted) return;

    await BiometricUnlockService.instance.storeSecret(current);
    await settings.setBiometricsEnabled(true);
    if (mounted) setState(() => _biometricsEnabled = true);
  }

  Future<void> _showUnlockMethodPicker() async {
    final km = widget.keyManager;
    if (km == null) return;
    final current = settings.unlockType;
  UnlockType? selected = current;

    final picked = await showPrysmSheet<UnlockType>(
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
                      style: context.prysmStyle.headlineStyle,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Switching methods requires setting a new unlock code.',
                      style: context.prysmStyle.captionStyle,
                    ),
                    const SizedBox(height: 16),
                    PrysmRadioRow<UnlockType>(
                      title: '6-digit PIN',
                      value: UnlockType.pin,
                      groupValue: selected,
                      onChanged: (v) => setModalState(() => selected = v),
                    ),
                    PrysmRadioRow<UnlockType>(
                      title: 'Passphrase (12+ characters)',
                      value: UnlockType.passphrase,
                      groupValue: selected,
                      onChanged: (v) => setModalState(() => selected = v),
                    ),
                    const SizedBox(height: 8),
                    PrysmButton(
                      label: 'Continue',
                      onPressed: selected == null || selected == current
                          ? null
                          : () => Navigator.pop(ctx, selected),
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
    showPrysmSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            PrysmListRow(
              leading: const Icon(PrysmIcons.settingsInputComponentOutlined),
              title: 'System default',
              trailing: _linuxSelectedDeviceId == null
                  ? const Icon(PrysmIcons.check)
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
              PrysmListRow(
                leading: const Icon(PrysmIcons.micOutlined),
                title: device.name,
                subtitle: device.isDefault ? 'Default input' : null,
                trailing: _linuxSelectedDeviceId == device.id
                    ? const Icon(PrysmIcons.check)
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
    showPrysmSheet<void>(
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
                  style: ctx.prysmStyle.captionStyle,
                ),
              ),
              PrysmListRow(
                leading: const Icon(PrysmIcons.folderOpenOutlined),
                title: 'Choose folder',
                onTap: () async {
                  Navigator.pop(ctx);
                  await _pickDownloadLocation();
                },
              ),
              PrysmListRow(
                leading: const Icon(PrysmIcons.restoreOutlined),
                title: 'Use system default',
                onTap: () async {
                  Navigator.pop(ctx);
                  await settings.clearCustomDownloadPath();
                  await _loadDownloadLocationDisplay();
                  if (mounted) {
                    showPrysmToast(context, 'Download location reset to default');
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
        showPrysmToast(context, 'Selected folder does not exist');
      }
      return;
    }

    await settings.setCustomDownloadPath(path);
    await _loadDownloadLocationDisplay();
    if (mounted) {
      showPrysmToast(context, 'Downloads will be saved to $path');
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
      final confirmed = await showPrysmConfirmDialog(
        context: context,
        title: 'Enable voice transcription?',
        content: const Text(
          'Prysm will download an on-device English speech model (~110 MB). '
          'Only English voice messages can be transcribed for now. '
          'Transcripts stay on this device and are never sent to contacts.',
        ),
        cancelLabel: 'Cancel',
        confirmLabel: 'Enable',
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
          showPrysmToast(context, 'Failed to download speech model: $e');
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
    showPrysmDialog(
      context: context,
      title: 'About ${settings.name}',
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Version ${settings.version}'),
          const SizedBox(height: 16),
          Text(settings.description),
          const SizedBox(height: 16),
          const Text('Features:'),
          const Text('• End-to-end encryption'),
          const Text('• Tor network routing'),
          const Text('• No central servers'),
          const Text('• Open source'),
        ],
      ),
      confirmLabel: 'OK',
    );
  }

  void _showResetDialog() {
    showPrysmConfirmDialog(
      context: context,
      title: 'Reset All Settings?',
      content: const Text(
        'This will restore all settings to their default values. This action cannot be undone.',
      ),
      cancelLabel: 'Cancel',
      confirmLabel: 'Reset',
      confirmVariant: PrysmButtonVariant.danger,
    ).then((confirmed) async {
      if (confirmed != true || !mounted) return;
      await settings.reset();
      _loadSettings();
      widget.onThemeChanged(0);
      if (mounted) {
        showPrysmToast(context, 'Settings reset to defaults');
      }
    });
  }

  void _showBackupDialog() => showCreateBackupDialog(context);

  void _openOnboardingReplay() {
    final onion = widget.onionAddress;
    if (onion == null) return;
    Navigator.of(context).push(
      PrysmPageRoute(page: OnboardingScreen(
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
    showPrysmDialog(
      context: context,
      title: 'Restore Backup',
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'This will replace all current data with the backup. The app will restart after restore.',
            style: TextStyle(
              fontSize: 14,
              color: context.prysmStyle.tokens.danger,
            ),
          ),
          const SizedBox(height: 16),
          PrysmTextField(
            controller: passwordController,
            labelText: 'Backup Password',
            obscureText: true,
            prefixIcon: const Icon(PrysmIcons.lock),
          ),
        ],
      ),
      cancelLabel: 'Cancel',
      confirmLabel: 'Restore',
      onConfirm: () async {
        final password = passwordController.text;
        Navigator.pop(context);
        await _performRestore(password);
      },
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
          showPrysmToast(context, 'No backup files found in $location');
          return;
        }

        if (!mounted) return;
        final chosen = await showPrysmSheet<File>(
          context: context,
          builder: (context) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    'Select Backup',
                    style: context.prysmStyle.headlineStyle,
                  ),
                ),
                for (final f in files)
                  PrysmListRow(
                    title: p.basename(f.path),
                    onTap: () => Navigator.pop(context, f),
                  ),
              ],
            ),
          ),
        );
        if (chosen == null) return;
        filePath = chosen.path;
      }

      final ok = await BackupService.restoreBackup(filePath, password);
      if (mounted) {
        if (ok) {
          showPrysmToast(context, 'Backup restored! Please restart the app.');
        } else {
          showPrysmToast(context, 'Restore failed — wrong password or corrupt file');
        }
      }
    } catch (e) {
      if (mounted) {
        showPrysmToast(context, 'Restore failed: $e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return PrysmScaffold(
      title: 'Settings',
      leading: PrysmIconButton(icon: PrysmIcons.arrowBack, onPressed: widget.onClose),
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ==================== APPEARANCE ====================
              _buildSectionHeader('Appearance'),
              const SizedBox(height: 12),
              _buildCard([
                _buildThemeOption('Light Mode', PrysmIcons.lightMode, 0),
                const PrysmDivider(),
                _buildThemeOption('Dark Mode', PrysmIcons.darkMode, 1),
                const PrysmDivider(),
                _buildThemeOption('Pink Mode', PrysmIcons.autoAwesome, 2),
                const PrysmDivider(),
                _buildThemeOption('Cyan Mode', PrysmIcons.waterDrop, 3),
                const PrysmDivider(),
                _buildThemeOption(
                  'Purple Mode',
                  PrysmIcons.autoAwesome,
                  4,
                ),
                const PrysmDivider(),
                _buildThemeOption('Orange Mode', PrysmIcons.whatshot, 5),
              ]),
              const SizedBox(height: 16),
              _buildCard([
                AppearanceSettingsSection(
                  onChanged: () => widget.onAppearanceChanged?.call(),
                ),
              ]),

              const SizedBox(height: 30),

              // ==================== PRIVACY ====================
              _buildSectionHeader('Privacy'),
              const SizedBox(height: 12),
              _buildCard([
                if (widget.keyManager != null) ...[
                  _buildNavigationTile(
                    'Unlock method',
                    PrysmIcons.lock,
                    _showUnlockMethodPicker,
                    subtitle: settings.unlockType == UnlockType.pin
                        ? '6-digit PIN'
                        : 'Passphrase (12+ characters)',
                  ),
                  const PrysmDivider(),
                  _buildNavigationTile(
                    'Change passcode',
                    PrysmIcons.pin,
                    () => runChangePasscodeFlow(context, widget.keyManager!),
                    subtitle: settings.unlockType == UnlockType.pin
                        ? 'Update your unlock PIN without changing your identity'
                        : 'Update your unlock passphrase without changing your identity',
                  ),
                  const PrysmDivider(),
                  if (Platform.isAndroid && _biometricsAvailable) ...[
                    _buildSwitchTile(
                      'Unlock with biometrics',
                      'Skip PIN or passphrase using fingerprint or face',
                      PrysmIcons.fingerprint,
                      _biometricsEnabled,
                      _onBiometricsToggled,
                    ),
                    const PrysmDivider(),
                  ],
                ],
                _buildNavigationTile(
                  'Blocked contacts',
                  PrysmIcons.blockOutlined,
                  () {
                    Navigator.push(
                      context,
                      PrysmPageRoute(page: BlockedContactsScreen(
                          onClose: () => Navigator.of(context).pop(),
                        ),
                      ),
                    );
                  },
                ),
                const PrysmDivider(),
                _buildNavigationTile(
                  'Advanced Privacy',
                  PrysmIcons.privacyTip,
                  () {
                    Navigator.push(
                      context,
                      PrysmPageRoute(page: PrivacySettingsScreen(
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
                if (widget.offlineMode) ...[
                  _buildNavigationTile(
                    widget.torConnecting ? 'Connecting to Tor…' : 'Connect Tor',
                    PrysmIcons.link,
                    widget.torConnecting
                        ? null
                        : () => widget.onConnectTor?.call(),
                    subtitle: 'Go online to send and receive messages',
                  ),
                ] else ...[
                  _buildNavigationTile(
                    'Refresh Tor Circuit',
                    PrysmIcons.sync,
                    () async {
                      if (widget.torManager == null) return;
                      final ok = await widget.torManager.refreshCircuit();
                      if (!context.mounted) return;
                      showPrysmToast(
                        context,
                        ok
                            ? 'New Tor circuit requested'
                            : 'Failed to refresh circuit',
                      );
                    },
                    subtitle: 'Request a new circuit when connections are stuck',
                  ),
                ],
                if (kDebugMode) ...[
                  _buildSwitchTile(
                    'Enable Relay Server',
                    'COMING SOON, NOT WORKING', //'Use relay for offline message delivery',
                    PrysmIcons.cloudOutlined,
                    _enableRelay,
                    (bool value) {
                      return true;
                    }, //_onEnableRelayToggle,
                  ),
                ]
                // if (_enableRelay) ...[
                //   const PrysmDivider(),
                //   _buildNavigationTile(
                //     'Relay Address',
                //     PrysmIcons.dnsOutlined,
                //     _showRelayAddressDialog,
                //     subtitle: _relayAddress ?? 'Not configured',
                //   ),
                // ],
                // const PrysmDivider(),
                // _buildSwitchTile(
                //   'Aggressive Retry',
                //   'Retry sending messages more frequently',
                //   PrysmIcons.refreshOutlined,
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
                  PrysmIcons.notificationsOutlined,
                  _notificationsEnabled,
                  _onNotificationToggle,
                ),
                const PrysmDivider(),
                _buildSwitchTile(
                  'Battery saving',
                  BatterySaverService.instance.statusSubtitle,
                  PrysmIcons.batterySaverOutlined,
                  BatterySaverService.instance.isActive,
                  _onBatterySavingToggle,
                ),
                if (widget.onionAddress != null) ...[
                  const PrysmDivider(),
                  _buildNavigationTile(
                    'Getting started',
                    PrysmIcons.tourOutlined,
                    _openOnboardingReplay,
                    subtitle: 'Replay the setup tour',
                  ),
                ],
                if (!Platform.isAndroid && !Platform.isIOS) ...[
                  const PrysmDivider(),
                  _buildSwitchTile(
                    'Minimize to system tray on close',
                    'Keep Prysm running in the tray when closing the window',
                    PrysmIcons.minimizeOutlined,
                    _minimizeToTray,
                    _onMinimizeToTrayToggle,
                  ),
                  const PrysmDivider(),
                  _buildSwitchTile(
                    'Minimize to tray when minimizing window',
                    'Hide to tray when clicking the minimize button',
                    PrysmIcons.keyboardArrowDownOutlined,
                    _minimizeOnMinimizeButton,
                    _onMinimizeOnMinimizeButtonToggle,
                  ),
                ],
                if (!kIsWeb && Platform.isLinux) ...[
                  const PrysmDivider(),
                  _buildNavigationTile(
                    'Call microphone',
                    PrysmIcons.micOutlined,
                    _showLinuxInputDeviceSheet,
                    subtitle: _linuxSelectedDeviceLabel,
                  ),
                ],
                // const PrysmDivider(),
                // _buildNavigationTile(
                //   'Data & Storage',
                //   PrysmIcons.storageOutlined,
                //   () {
                //     Navigator.push(
                //       context,
                //       PrysmPageRoute(page: 
                //         builder: (context) => DataStorageScreen(
                //           onClose: () => Navigator.of(context).pop(),
                //         ),
                //       ),
                //     );
                //   },
                // ),
                // const PrysmDivider(),
                // _buildNavigationTile(
                //   'Message Retention',
                //   PrysmIcons.deleteSweepOutlined,
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
                  PrysmIcons.previewOutlined,
                  _enableFilePreview,
                  _onFilePreviewToggle,
                ),
                const PrysmDivider(),
                _buildSwitchTile(
                  'Link previews',
                  'Fetch titles and images for URLs in messages via Tor',
                  PrysmIcons.linkOutlined,
                  _enableLinkUnfurling,
                  _onLinkUnfurlingToggle,
                ),
                const PrysmDivider(),
                _buildSwitchTile(
                  'Voice transcription',
                  'Transcribe English voice messages on this device. Text stays local and is never sent to contacts.',
                  PrysmIcons.subtitlesOutlined,
                  _enableVoiceTranscription,
                  _onVoiceTranscriptionToggle,
                ),
                if (_isDownloadingSttModel) ...[
                  const PrysmDivider(),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Downloading speech model…',
                          style: context.prysmStyle.captionStyle,
                        ),
                        const SizedBox(height: 6),
                        PrysmLinearProgressIndicator(
                          value: _sttModelDownloadProgress > 0
                              ? _sttModelDownloadProgress
                              : null,
                        ),
                      ],
                    ),
                  ),
                ],
                const PrysmDivider(),
                _buildNavigationTile(
                  'Download Location',
                  PrysmIcons.downloadOutlined,
                  _showDownloadLocationSheet,
                  subtitle: _downloadLocationDisplay,
                ),
                const PrysmDivider(),
                _buildNavigationTile(
                  'Create Backup',
                  PrysmIcons.backupOutlined,
                  _showBackupDialog,
                  subtitle: 'Export encrypted backup file',
                ),
                const PrysmDivider(),
                _buildNavigationTile(
                  'Restore Backup',
                  PrysmIcons.restoreOutlined,
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
                  PrysmIcons.infoOutlined,
                  _showAboutDialog,
                  subtitle: 'Version ${settings.version}',
                ),
                const PrysmDivider(),
                _buildNavigationTile(
                  'Source Code',
                  PrysmIcons.codeOutlined,
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
              _buildSectionHeader('Danger Zone', color: context.prysmStyle.tokens.danger),
              const SizedBox(height: 12),
              _buildCard([
                _buildNavigationTile(
                  'Reset Settings',
                  PrysmIcons.restoreOutlined,
                  _showResetDialog,
                  subtitle: 'Restore default settings',
                  textColor: context.prysmStyle.tokens.danger,
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
    final tokens = context.prysmTokens;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.6,
          color: color ?? tokens.textMuted,
        ),
      ),
    );
  }

  Widget _buildCard(List<Widget> children) {
    final tokens = context.prysmTokens;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: tokens.surface,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: children),
    );
  }

  Widget _buildThemeOption(String title, IconData icon, int themeIndex) {
    final bool isSelected = _selectedTheme == themeIndex;
    final themeAccent = PrysmThemes.forIndex(themeIndex).tokens.accent;
    final tokens = context.prysmTokens;

    Color getTextColor() {
      if (isSelected) return themeAccent;
      return tokens.textPrimary;
    }

    return PrysmListRow(
      leading: Icon(
        icon,
        color: isSelected ? getTextColor() : context.prysmStyle.tokens.textSecondary,
      ),
      titleWidget: Text(
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
            color: isSelected ? getTextColor() : context.prysmStyle.tokens.divider,
            width: 2,
          ),
          color: isSelected ? getTextColor() : const Color(0x00000000),
        ),
        child: isSelected
            ? Icon(
                PrysmIcons.check,
                size: 16,
                color: (themeIndex == 1 || themeIndex == 4 || themeIndex == 5)
                    ? const Color(0x87000000)
                    : const Color(0xFFFFFFFF),
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
    return PrysmListRow(
      leading: Icon(icon),
      title: title,
      subtitle: subtitle,
      trailing: PrysmSwitch(
        value: value,
        onChanged: onChanged,
      ),
      onTap: () => onChanged(!value),
    );
  }

  Widget _buildNavigationTile(
    String title,
    IconData icon,
    VoidCallback? onTap, {
    String? subtitle,
    Color? textColor,
  }) {
    return PrysmListRow(
      leading: Icon(icon, color: textColor),
      title: textColor == null ? title : null,
      titleWidget: textColor != null
          ? Text(title, style: TextStyle(color: textColor))
          : null,
      subtitle: subtitle,
      trailing: Icon(PrysmIcons.arrowForwardIos, size: 16, color: textColor),
      onTap: onTap,
    );
  }
}
