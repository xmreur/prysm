// lib/screens/settings_screen.dart
import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:prysm/services/backup_service.dart';
import 'package:prysm/screens/widgets/backup_flow.dart';
import 'package:prysm/screens/onboarding/onboarding_screen.dart';
import 'package:prysm/services/tray_service.dart';
import 'package:prysm/services/battery_saver_service.dart';
import 'package:prysm/services/app_update_service.dart';
import 'package:prysm/services/settings_service.dart';
import 'package:prysm/services/call/linux_audio_settings.dart';
import 'package:prysm_linux_audio/prysm_linux_audio.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:prysm/util/download_location.dart';
import 'package:prysm/util/group_pending_invite_store.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/log_export_helper.dart';
import 'package:prysm/util/obfs4_bridge_parser.dart';
import 'package:prysm/util/obfs4_desktop_preflight.dart';
import 'package:prysm/util/tor_bridge_config_factory.dart';
import 'package:prysm/models/unlock_type.dart';
import 'package:prysm/services/biometric_unlock_service.dart';
import 'package:prysm/screens/widgets/change_passcode_flow.dart';
import 'privacy_settings_screen.dart';
import 'blocked_contacts_screen.dart';
import 'invite_requests_screen.dart';
import 'call_history_screen.dart';
import 'data_storage_screen.dart';
import 'package:prysm/screens/widgets/appearance_settings_section.dart';
import 'package:prysm/theme/prysm_theme.dart';
import 'package:prysm/theme/prysm_themes.dart';
import 'package:prysm/ui/prysm_scaffold.dart';

import 'package:flutter/widgets.dart';
import 'package:prysm/ui/core/prysm_icons.dart';
import 'package:prysm/ui/core/prysm_app.dart';
import 'package:prysm/ui/core/prysm_toast.dart';
import 'package:prysm/theme/prysm_style_scope.dart';
import 'package:prysm/ui/core/prysm_button.dart';
import 'package:prysm/ui/core/prysm_switch.dart';
import 'package:prysm/ui/core/prysm_list_row.dart';
import 'package:prysm/ui/core/prysm_divider.dart';
import 'package:prysm/ui/core/prysm_dialog.dart';
import 'package:prysm/ui/core/prysm_radio.dart';
import 'package:prysm/ui/core/prysm_text_field.dart';
import 'package:prysm/models/locale_override.dart';
import 'package:prysm/l10n/l10n_extensions.dart';
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
  final Future<void> Function()? onApplyTorBridgeSettings;
  final bool decoyMode;

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
    this.onApplyTorBridgeSettings,
    this.decoyMode = false,
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
  bool _useObfs4 = false;
  bool _applyingObfs4 = false;
  late final TextEditingController _obfs4BridgesController;
  bool _biometricsEnabled = false;
  bool _biometricsAvailable = false;
  LocaleOverride _localeOverride = LocaleOverride.system;
  int _pendingInviteCount = 0;
  String? _downloadLocationDisplay;
  List<LinuxAudioDevice> _linuxInputDevices = const [];
  String? _linuxSelectedDeviceId;
  String? _linuxSelectedDeviceLabel;
  StreamSubscription<void>? _batterySaverSub;

  @override
  void initState() {
    super.initState();
    _obfs4BridgesController = TextEditingController(
      text: settings.obfs4Bridges,
    );
    _loadSettings();
    _loadDownloadLocationDisplay();
    unawaited(_loadPendingInviteCount());
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
    _obfs4BridgesController.dispose();
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
      _useObfs4 = settings.useObfs4;
      _obfs4BridgesController.text = settings.obfs4Bridges;
      _biometricsEnabled = settings.biometricsEnabled;
      _localeOverride = settings.localeOverride;
    });
  }

  Future<void> _onLocaleOverrideChanged(LocaleOverride? value) async {
    if (value == null) return;
    setState(() => _localeOverride = value);
    await settings.setLocaleOverride(value);
  }

  Future<void> _loadBiometricsState() async {
    final available = await BiometricUnlockService.instance.isAvailable();
    if (mounted) {
      setState(() => _biometricsAvailable = available);
    }
  }

  Future<void> _loadPendingInviteCount() async {
    final count = await GroupPendingInviteStore.count();
    if (!mounted) return;
    setState(() => _pendingInviteCount = count);
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
                      context.l10n.unlockMethod,
                      style: context.prysmStyle.headlineStyle,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      context.l10n.switchingMethodsRequiresSettingANewUnlockCode,
                      style: context.prysmStyle.captionStyle,
                    ),
                    const SizedBox(height: 16),
                    PrysmRadioRow<UnlockType>(
                      title: context.l10n.str6digitpin,
                      value: UnlockType.pin,
                      groupValue: selected,
                      onChanged: (v) => setModalState(() => selected = v),
                    ),
                    PrysmRadioRow<UnlockType>(
                      title: context.l10n.passphrase12Characters,
                      value: UnlockType.passphrase,
                      groupValue: selected,
                      onChanged: (v) => setModalState(() => selected = v),
                    ),
                    const SizedBox(height: 8),
                    PrysmButton(
                      label: context.l10n.continueLabel,
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
      return defaultDevice?.name ?? SettingsService().localizations.systemDefault;
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
              title: context.l10n.systemDefault,
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
                subtitle: device.isDefault ? context.l10n.defaultInput : null,
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
                  _downloadLocationDisplay ?? context.l10n.loading,
                  style: ctx.prysmStyle.captionStyle,
                ),
              ),
              PrysmListRow(
                leading: const Icon(PrysmIcons.folderOpenOutlined),
                title: context.l10n.chooseFolder,
                onTap: () async {
                  Navigator.pop(ctx);
                  await _pickDownloadLocation();
                },
              ),
              PrysmListRow(
                leading: const Icon(PrysmIcons.restoreOutlined),
                title: context.l10n.useSystemDefault,
                onTap: () async {
                  Navigator.pop(ctx);
                  await settings.clearCustomDownloadPath();
                  await _loadDownloadLocationDisplay();
                  if (mounted) {
                    showPrysmToast(context, context.l10n.downloadLocationResetToDefault);
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
      dialogTitle: context.l10n.chooseDownloadFolder,
    );
    if (path == null) return;

    final dir = Directory(path);
    if (!await dir.exists()) {
      if (mounted) {
        showPrysmToast(context, context.l10n.selectedFolderDoesNotExist);
      }
      return;
    }

    await settings.setCustomDownloadPath(path);
    await _loadDownloadLocationDisplay();
    if (mounted) {
      showPrysmToast(context, context.l10n.downloadsWillBeSavedToPath(path));
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

  Future<void> _applyObfs4Settings({
    required bool useObfs4,
    required String bridgesText,
  }) async {
    if (_applyingObfs4) return;

    final parsed = Obfs4BridgeParser.parse(bridgesText);
    if (parsed.errors.isNotEmpty) {
      if (!mounted) return;
      showPrysmToast(context, parsed.errors.first);
      return;
    }
    if (useObfs4 && parsed.bridges.isEmpty) {
      if (!mounted) return;
      showPrysmToast(
        context,
        'Paste at least one valid obfs4 bridge line before enabling.',
      );
      return;
    }

    final online = !widget.offlineMode && !widget.torConnecting;
    if (online) {
      final confirmed = await showPrysmConfirmDialog(
        context: context,
        title: 'Reconnect over Tor?',
        content: const Text(
          'Tor will restart to apply obfs4 bridge settings. Active connections will drop briefly.',
        ),
        cancelLabel: 'Cancel',
        confirmLabel: 'Reconnect',
      );
      if (confirmed != true) {
        _loadSettings();
        return;
      }
    }

    setState(() => _applyingObfs4 = true);
    try {
      if (useObfs4 && !Platform.isAndroid && !Platform.isIOS) {
        final bridgeConfig = torBridgeConfigFromSettings(
          settings.settings.copyWith(
            useObfs4: useObfs4,
            obfs4Bridges: bridgesText.trim(),
          ),
        );
        await preflightDesktopObfs4(bridgeConfig);
      }

      await settings.setObfs4BridgeSettings(
        useObfs4: useObfs4,
        obfs4Bridges: bridgesText.trim(),
      );
      if (!mounted) return;
      setState(() {
        _useObfs4 = useObfs4;
        _obfs4BridgesController.text = bridgesText.trim();
      });

      if (online) {
        final apply = widget.onApplyTorBridgeSettings;
        if (apply != null) {
          await apply();
        }
      }

      if (!mounted) return;
      showPrysmToast(
        context,
        online
            ? 'obfs4 settings applied — Tor is reconnecting'
            : 'obfs4 settings saved',
      );
    } catch (e) {
      if (!mounted) return;
      showPrysmToast(
        context,
        obfs4FailureMessage(e, useObfs4: useObfs4),
      );
      _loadSettings();
    } finally {
      if (mounted) setState(() => _applyingObfs4 = false);
    }
  }

  Future<void> _onUseObfs4Toggle(bool value) async {
    await _applyObfs4Settings(
      useObfs4: value,
      bridgesText: _obfs4BridgesController.text,
    );
  }

  Future<void> _saveObfs4Bridges() async {
    await _applyObfs4Settings(
      useObfs4: _useObfs4,
      bridgesText: _obfs4BridgesController.text,
    );
  }
  void _onBatterySavingToggle(bool value) async {
    await BatterySaverService.instance.setUserEnabled(value);
    if (mounted) setState(() {});
  }

  Future<void> _checkForUpdates() async {
    if (Platform.isIOS) {
      showPrysmToast(context, context.l10n.updatesAreNotAvailableOnIos);
      return;
    }
    final message = await AppUpdateService().checkFromSettings(context);
    if (!mounted || message == null) return;
    showPrysmToast(context, message);
  }

  Future<void> _debugPreviewUpdateDialog() async {
    await AppUpdateService().debugPreviewUpdateDialog(context);
  }

  Future<void> _debugTestUpdateFlow() async {
    final message = await AppUpdateService().debugTestUpdateFlow(context);
    if (!mounted) return;
    if (message != null) showPrysmToast(context, message);
  }

  void _showAboutDialog() {
    showPrysmDialog(
      context: context,
      title: context.l10n.aboutApp(settings.name),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(context.l10n.versionLabel(settings.version)),
          const SizedBox(height: 16),
          Text(settings.description),
          const SizedBox(height: 16),
          Text(context.l10n.features),
          Text(context.l10n.endToEndEncryption),
          Text(context.l10n.torNetworkRouting),
          Text(context.l10n.noCentralServers),
          Text(context.l10n.openSource),
        ],
      ),
      confirmLabel: context.l10n.ok,
    );
  }

  void _showResetDialog() {
    showPrysmConfirmDialog(
      context: context,
      title: context.l10n.resetAllSettings,
      content: Text(
        context.l10n.thisWillRestoreAllSettingsToTheirDefault,
      ),
      cancelLabel: context.l10n.cancel,
      confirmLabel: context.l10n.reset,
      confirmVariant: PrysmButtonVariant.danger,
    ).then((confirmed) async {
      if (confirmed != true || !mounted) return;
      await settings.reset();
      _loadSettings();
      widget.onThemeChanged(0);
      if (mounted) {
        showPrysmToast(context, context.l10n.settingsResetToDefaults);
      }
    });
  }

  void _showBackupDialog() => showCreateBackupDialog(context);

  void _showExportLogDialog() {
    showPrysmConfirmDialog(
      context: context,
      title: context.l10n.exportLog,
      content: Text(
        context.l10n.theLogFileMayContainSensitiveInformationOnly,
      ),
      cancelLabel: context.l10n.cancel,
      confirmLabel: context.l10n.export,
    ).then((confirmed) async {
      if (confirmed != true || !mounted) return;
      await exportLog(context);
    });
  }

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
      title: context.l10n.restoreBackup,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            context.l10n.thisWillReplaceAllCurrentDataWithThe,
            style: TextStyle(
              fontSize: 14,
              color: context.prysmStyle.tokens.danger,
            ),
          ),
          const SizedBox(height: 16),
          PrysmTextField(
            controller: passwordController,
            labelText: context.l10n.backupPassword,
            obscureText: true,
            prefixIcon: const Icon(PrysmIcons.lock),
          ),
        ],
      ),
      cancelLabel: context.l10n.cancel,
      confirmLabel: context.l10n.restore,
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
          dialogTitle: context.l10n.selectBackupFile,
          type: FileType.any,
        );
        if (result == null || result.files.single.path == null) return;
        filePath = result.files.single.path!;
      } else {
        final files = await DownloadLocation.listBackupFiles();
        if (files.isEmpty) {
          final location = await DownloadLocation.displayPath();
          if (!mounted) return;
          showPrysmToast(
            context,
            context.l10n.noBackupFilesFoundInLocation(location),
          );
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
                    context.l10n.selectBackup,
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
          showPrysmToast(context, context.l10n.backupRestoredPleaseRestartTheApp);
        } else {
          showPrysmToast(context, context.l10n.restoreFailedWrongPasswordOrCorruptFile);
        }
      }
    } catch (e) {
      if (mounted) {
        showPrysmToast(context, context.l10n.restoreFailedE(e.toString()));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return PrysmScaffold(
      title: context.l10n.settings,
      leading: PrysmIconButton(icon: PrysmIcons.arrowBack, onPressed: widget.onClose),
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ==================== APPEARANCE ====================
              _buildSectionHeader(context.l10n.appearance),
              const SizedBox(height: 12),
              _buildCard([
                PrysmRadioRow<LocaleOverride>(
                  value: LocaleOverride.system,
                  groupValue: _localeOverride,
                  title: context.l10n.languageSystem,
                  subtitle: context.l10n.language,
                  onChanged: _onLocaleOverrideChanged,
                ),
                const PrysmDivider(),
                PrysmRadioRow<LocaleOverride>(
                  value: LocaleOverride.en,
                  groupValue: _localeOverride,
                  title: context.l10n.languageEnglish,
                  onChanged: _onLocaleOverrideChanged,
                ),
                const PrysmDivider(),
                PrysmRadioRow<LocaleOverride>(
                  value: LocaleOverride.it,
                  groupValue: _localeOverride,
                  title: context.l10n.languageItalian,
                  onChanged: _onLocaleOverrideChanged,
                ),
              ]),
              const SizedBox(height: 16),
              _buildCard([
                _buildThemeOption(context.l10n.lightMode, PrysmIcons.lightMode, 0),
                const PrysmDivider(),
                _buildThemeOption(context.l10n.darkMode, PrysmIcons.darkMode, 1),
                const PrysmDivider(),
                _buildThemeOption(context.l10n.pinkMode, PrysmIcons.autoAwesome, 2),
                const PrysmDivider(),
                _buildThemeOption(context.l10n.cyanMode, PrysmIcons.waterDrop, 3),
                const PrysmDivider(),
                _buildThemeOption(
                  context.l10n.purpleMode,
                  PrysmIcons.autoAwesome,
                  4,
                ),
                const PrysmDivider(),
                _buildThemeOption(context.l10n.orangeMode, PrysmIcons.whatshot, 5),
              ]),
              const SizedBox(height: 16),
              _buildCard([
                AppearanceSettingsSection(
                  onChanged: () => widget.onAppearanceChanged?.call(),
                ),
              ]),

              const SizedBox(height: 30),

              // ==================== PRIVACY ====================
              _buildSectionHeader(context.l10n.privacy),
              const SizedBox(height: 12),
              _buildCard([
                if (widget.keyManager != null) ...[
                  _buildNavigationTile(
                    context.l10n.unlockMethod,
                    PrysmIcons.lock,
                    _showUnlockMethodPicker,
                    subtitle: settings.unlockType == UnlockType.pin
                        ? context.l10n.str6digitpin
                        : context.l10n.passphrase12Characters,
                  ),
                  const PrysmDivider(),
                  _buildNavigationTile(
                    context.l10n.changePasscode,
                    PrysmIcons.pin,
                    () => runChangePasscodeFlow(context, widget.keyManager!),
                    subtitle: settings.unlockType == UnlockType.pin
                        ? context.l10n.updateUnlockPinSubtitle
                        : context.l10n.updateUnlockPassphraseSubtitle,
                  ),
                  const PrysmDivider(),
                  if (Platform.isAndroid && _biometricsAvailable) ...[
                    _buildSwitchTile(
                      context.l10n.unlockWithBiometrics,
                      context.l10n.skipPinOrPassphraseUsingBiometrics,
                      PrysmIcons.fingerprint,
                      _biometricsEnabled,
                      _onBiometricsToggled,
                    ),
                    const PrysmDivider(),
                  ],
                ],
                _buildNavigationTile(
                  context.l10n.blockedContacts,
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
                if (widget.keyManager != null && widget.onionAddress != null) ...[
                  _buildNavigationTile(
                    context.l10n.inviteRequests,
                    PrysmIcons.group,
                    () {
                      Navigator.push(
                        context,
                        PrysmPageRoute(
                          page: InviteRequestsScreen(
                            onClose: () => Navigator.of(context).pop(),
                            onionAddress: widget.onionAddress!,
                            keyManager: widget.keyManager!,
                            onChanged: _loadPendingInviteCount,
                          ),
                        ),
                      );
                    },
                    subtitle: context.l10n.requestCount(_pendingInviteCount),
                  ),
                  const PrysmDivider(),
                ],
                _buildNavigationTile(
                  context.l10n.advancedPrivacy,
                  PrysmIcons.privacyTip,
                  () {
                    // Switching to the strict mode inside this screen
                    // discards every held invite, so the count on the tile
                    // above is stale the moment we come back.
                    Navigator.push(
                      context,
                      PrysmPageRoute(page: PrivacySettingsScreen(
                          onClose: () => Navigator.of(context).pop(),
                          keyManager: widget.keyManager,
                        ),
                      ),
                    ).then((_) => _loadPendingInviteCount());
                  },
                ),
              ]),

              const SizedBox(height: 30),

              // ==================== NETWORK ====================
              _buildSectionHeader(context.l10n.network),
              const SizedBox(height: 12),
              _buildCard([
                if (widget.offlineMode) ...[
                  _buildNavigationTile(
                    widget.torConnecting
                        ? context.l10n.connectingToTor
                        : context.l10n.connectTor,
                    PrysmIcons.link,
                    widget.torConnecting
                        ? null
                        : () => widget.onConnectTor?.call(),
                    subtitle: context.l10n.goOnlineToSendAndReceiveMessages,
                  ),
                ] else ...[
                  _buildNavigationTile(
                    context.l10n.refreshTorCircuit,
                    PrysmIcons.sync,
                    () async {
                      if (widget.torManager == null) return;
                      final ok = await widget.torManager.refreshCircuit();
                      if (!context.mounted) return;
                      showPrysmToast(
                        context,
                        ok
                            ? context.l10n.newTorCircuitRequested
                            : context.l10n.failedToRefreshCircuit,
                      );
                    },
                    subtitle: context.l10n.requestANewCircuitWhenConnectionsAreStuck,
                  ),
                ],
                if (!widget.decoyMode) ...[
                  const PrysmDivider(),
                  _buildSwitchTile(
                    'Use obfs4 bridges',
                    'Connect through your own obfs4 bridge when Tor is censored',
                    PrysmIcons.shieldOutlined,
                    _useObfs4,
                    _applyingObfs4 ? (_) {} : _onUseObfs4Toggle,
                  ),
                  const SizedBox(height: 12),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: PrysmTextField(
                      controller: _obfs4BridgesController,
                      labelText: 'obfs4 bridge lines',
                      hintText:
                          'obfs4 host:port fingerprint cert=… iat-mode=0\n(one per line)',
                      minLines: 3,
                      maxLines: 8,
                      enabled: !_applyingObfs4,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: PrysmListRow(
                      leading: const Icon(PrysmIcons.saveOutlined),
                      title: 'Save bridges & reconnect',
                      subtitle: 'Apply bridge line changes to Tor',
                      onTap: _applyingObfs4 ? null : _saveObfs4Bridges,
                    ),
                  ),
                ],
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
              _buildSectionHeader(context.l10n.general),
              const SizedBox(height: 12),
              _buildCard([
                _buildSwitchTile(
                  context.l10n.notifications,
                  context.l10n.showNotificationsForNewMessages,
                  PrysmIcons.notificationsOutlined,
                  _notificationsEnabled,
                  _onNotificationToggle,
                ),
                const PrysmDivider(),
                _buildSwitchTile(
                  context.l10n.batterySaving,
                  BatterySaverService.instance.statusSubtitle,
                  PrysmIcons.batterySaverOutlined,
                  BatterySaverService.instance.isActive,
                  _onBatterySavingToggle,
                ),
                if (widget.onionAddress != null) ...[
                  const PrysmDivider(),
                  _buildNavigationTile(
                    context.l10n.gettingStarted,
                    PrysmIcons.tourOutlined,
                    _openOnboardingReplay,
                    subtitle: context.l10n.replayTheSetupTour,
                  ),
                ],
                if (!Platform.isAndroid && !Platform.isIOS) ...[
                  const PrysmDivider(),
                  _buildSwitchTile(
                    context.l10n.minimizeToSystemTrayOnClose,
                    context.l10n.keepPrysmRunningInTrayWhenClosing,
                    PrysmIcons.minimizeOutlined,
                    _minimizeToTray,
                    _onMinimizeToTrayToggle,
                  ),
                  const PrysmDivider(),
                  _buildSwitchTile(
                    context.l10n.minimizeToTrayWhenMinimizingWindow,
                    context.l10n.hideToTrayWhenClickingMinimize,
                    PrysmIcons.keyboardArrowDownOutlined,
                    _minimizeOnMinimizeButton,
                    _onMinimizeOnMinimizeButtonToggle,
                  ),
                ],
                if (!kIsWeb && Platform.isLinux) ...[
                  const PrysmDivider(),
                  _buildNavigationTile(
                    context.l10n.callMicrophone,
                    PrysmIcons.micOutlined,
                    _showLinuxInputDeviceSheet,
                    subtitle:
                        _linuxSelectedDeviceLabel ?? context.l10n.systemDefault,
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
              _buildSectionHeader(context.l10n.data),
              const SizedBox(height: 12),
              _buildCard([
                _buildSwitchTile(
                  context.l10n.filePreviews,
                  context.l10n.filePreviewsInChatSubtitle,
                  PrysmIcons.previewOutlined,
                  _enableFilePreview,
                  _onFilePreviewToggle,
                ),
                const PrysmDivider(),
                _buildSwitchTile(
                  context.l10n.linkPreviews,
                  context.l10n.linkPreviewsViaTorSubtitle,
                  PrysmIcons.linkOutlined,
                  _enableLinkUnfurling,
                  _onLinkUnfurlingToggle,
                ),
                const PrysmDivider(),

                if (!widget.decoyMode)
                  _buildNavigationTile(
                    context.l10n.callHistory,
                    PrysmIcons.call,
                    () {
                      Navigator.push(
                        context,
                        PrysmPageRoute(
                          page: CallHistoryScreen(
                            onClose: () => Navigator.of(context).pop(),
                          ),
                        ),
                      );
                    },
                  ),
                if (!widget.decoyMode) const PrysmDivider(),
                _buildNavigationTile(
                  context.l10n.downloadLocation,
                  PrysmIcons.downloadOutlined,
                  _showDownloadLocationSheet,
                  subtitle: _downloadLocationDisplay ?? context.l10n.loading,
                ),
                if (!widget.decoyMode) const PrysmDivider(),
                if (!widget.decoyMode)
                  _buildNavigationTile(
                    context.l10n.storageManager,
                    PrysmIcons.storageOutlined,
                    () {
                      Navigator.push(
                        context,
                        PrysmPageRoute(
                          page: DataStorageScreen(
                            userId: widget.onionAddress,
                            keyManager: widget.keyManager,
                            onClose: () => Navigator.of(context).pop(),
                          ),
                        ),
                      );
                    },
                    subtitle: context.l10n.diskUsageAndMediaManagement,
                  ),
                const PrysmDivider(),
                _buildNavigationTile(
                  context.l10n.createBackup,
                  PrysmIcons.backupOutlined,
                  _showBackupDialog,
                  subtitle: context.l10n.exportEncryptedBackupFile,
                ),
                const PrysmDivider(),
                _buildNavigationTile(
                  context.l10n.restoreBackup,
                  PrysmIcons.restoreOutlined,
                  _showRestoreDialog,
                  subtitle: context.l10n.importFromBackupFile,
                ),
                const PrysmDivider(),
                _buildNavigationTile(
                  context.l10n.exportLog,
                  PrysmIcons.uploadFile,
                  _showExportLogDialog,
                  subtitle: context.l10n.saveDebugLogToDownloads,
                ),
              ]),

              const SizedBox(height: 30),

              // ==================== ABOUT ====================
              _buildSectionHeader(context.l10n.about),
              const SizedBox(height: 12),
              _buildCard([
                _buildNavigationTile(
                  context.l10n.checkForUpdates,
                  PrysmIcons.refreshOutlined,
                  () => unawaited(_checkForUpdates()),
                  subtitle: context.l10n.downloadFromGithubReleases,
                ),
                const PrysmDivider(),
                _buildNavigationTile(
                  context.l10n.aboutApp(settings.name),
                  PrysmIcons.infoOutlined,
                  _showAboutDialog,
                  subtitle: context.l10n.versionLabel(settings.version),
                ),
                const PrysmDivider(),
                _buildNavigationTile(
                  context.l10n.sourceCode,
                  PrysmIcons.codeOutlined,
                  () async {
                    await launchUrl(
                      Uri.parse('https://github.com/xmreur/prysm'),
                      mode: LaunchMode.externalApplication,
                    );
                  },
                  subtitle: context.l10n.viewOnGithub,
                ),
              ]),

              if (kDebugMode) ...[
                const SizedBox(height: 30),
                _buildSectionHeader(context.l10n.debugOptions),
                const SizedBox(height: 12),
                _buildCard([
                  _buildSwitchTile(
                    context.l10n.enableRelayServer,
                    context.l10n.comingSoonNotWorking,
                    PrysmIcons.cloudOutlined,
                    _enableRelay,
                    (bool value) {
                      return true;
                    },
                  ),
                  const PrysmDivider(),
                  _buildNavigationTile(
                    context.l10n.previewUpdateDialog,
                    PrysmIcons.codeOutlined,
                    () => unawaited(_debugPreviewUpdateDialog()),
                    subtitle: context.l10n.mockUpdateUiNoDownload,
                  ),
                  const PrysmDivider(),
                  _buildNavigationTile(
                    context.l10n.testUpdateFlow,
                    PrysmIcons.codeOutlined,
                    () => unawaited(_debugTestUpdateFlow()),
                    subtitle: context.l10n.skipVersionCheckDesktopDryRun,
                  ),
                ]),
              ],

              const SizedBox(height: 30),

              // ==================== DANGER ZONE ====================
              _buildSectionHeader(context.l10n.dangerZone, color: context.prysmStyle.tokens.danger),
              const SizedBox(height: 12),
              _buildCard([
                _buildNavigationTile(
                  context.l10n.resetSettings,
                  PrysmIcons.restoreOutlined,
                  _showResetDialog,
                  subtitle: context.l10n.restoreDefaultSettings,
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
