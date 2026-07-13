import 'package:flutter/widgets.dart';
import 'package:prysm/ui/core/prysm_icons.dart';
import 'package:prysm/ui/core/prysm_progress.dart';
import 'package:prysm/ui/core/prysm_toast.dart';
import 'package:prysm/theme/prysm_style_scope.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:prysm/database/messages.dart';
import 'package:prysm/database/self_messages_db.dart';
import 'package:prysm/models/panic_action.dart';
import 'package:prysm/models/unlock_type.dart';
import 'package:prysm/screens/unlock_screen.dart';
import 'package:prysm/screens/crypto_migration_screen.dart';
import 'package:prysm/screens/startup_fatal_error_screen.dart';
import 'package:prysm/crypto/key_store.dart';
import 'package:prysm/services/panic_pin_service.dart';
import 'package:prysm/services/panic_wipe_service.dart';
import 'package:prysm/services/unlock_lockout_service.dart';
import 'package:prysm/screens/settings_screen.dart';
import 'package:prysm/server/PrysmServer.dart';
import 'package:prysm/services/battery_saver_service.dart';
import 'package:prysm/services/block_service.dart';
import 'package:prysm/services/file_transfer_handler.dart';
import 'package:prysm/services/notification_mute_service.dart';
import 'package:prysm/services/active_conversation_tracker.dart';
import 'package:prysm/services/notification_open_chat_resolver.dart';
import 'package:prysm/services/pending_call_action.dart';
import 'package:prysm/services/pending_notification_route.dart';
import 'package:prysm/services/settings_service.dart';
import 'package:prysm/util/battery_saver_policy.dart';
import 'package:prysm/services/tray_service.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/logging.dart';
import 'package:prysm/util/updater_downloader.dart';
import 'package:prysm/screens/call/call_overlay.dart';
import 'package:prysm/services/call/call_foreground_session.dart';
import 'package:prysm/services/call/call_manager.dart';
import 'package:prysm/screens/chat.dart';
import 'package:prysm/screens/self_chat_screen.dart';
import 'package:prysm/screens/create_group_screen.dart';
import 'package:prysm/screens/group_chat.dart';
import 'package:prysm/models/conversation.dart';
import 'package:prysm/models/conversation_preferences.dart';
import 'package:prysm/models/group.dart';
import 'package:prysm/services/conversation_preferences_service.dart';
import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:prysm/models/detached_chat_launch.dart';
import 'package:prysm/screens/detached_chat_app.dart';
import 'package:prysm/services/detached_chat_bridge.dart';
import 'package:prysm/services/detached_chat_host.dart';
import 'package:prysm/services/detached_chat_window_registry.dart';
import 'package:prysm/screens/widgets/conversation_context_menu.dart';
import 'package:prysm/screens/widgets/conversation_actions_sheet.dart';
import 'package:prysm/services/group_service.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/util/app_bootstrap.dart';
import 'package:prysm/util/desktop_platform.dart';
import 'package:prysm/util/sqflite_platform.dart';
import 'package:prysm/util/tor_service.dart'; // Updated Tor service
import 'package:prysm/util/tor_downloader.dart';
import 'package:prysm/transport/peer_transport_registry.dart';
import 'package:prysm/transport/transport_provider.dart';
import 'package:prysm/util/tor_lifecycle_state.dart';
import 'package:prysm/util/tor_runtime_gate.dart';
import 'package:prysm/util/tor_supervisor.dart';
import 'package:prysm/screens/profile_screen.dart';
import 'package:prysm/screens/widgets/contact_avatar.dart';
import 'package:prysm/models/contact.dart';
import 'package:prysm/theme/prysm_theme.dart';
import 'package:prysm/screens/home/empty_home_state.dart';
import 'package:prysm/ui/prysm_list_row.dart';
import 'package:prysm/ui/prysm_search_field.dart';
import 'package:prysm/ui/core/prysm_app.dart';
import 'package:prysm/ui/core/prysm_button.dart';
import 'package:prysm/ui/core/prysm_pressable.dart';
import 'package:prysm/util/notification_service.dart';
import 'package:prysm/util/conversation_refresh_notifier.dart';
import 'package:prysm/util/group_membership_notifier.dart';
import 'package:prysm/util/tor_bootstrap_notifier.dart';
import 'package:prysm/screens/widgets/add_contact_dialog.dart';
import 'package:prysm/screens/widgets/qr_scanner_screen.dart';
import 'package:prysm/screens/widgets/prysm_id_qr.dart';
import 'package:prysm/util/onion_id_codec.dart';
import 'package:prysm/util/decoy_session_data.dart';
import 'package:prysm/screens/decoy_chat_screen.dart';
import 'package:prysm/screens/onboarding/onboarding_screen.dart';
import 'package:prysm/services/contact_add_service.dart';
import 'package:prysm/util/qr_platform.dart';
import 'package:prysm/util/tor_connection_notifier.dart';
import 'package:prysm/util/local_onion_address.dart';
import 'package:prysm/util/network_reachability.dart';
import 'package:prysm/services/read_receipt_service.dart';
import 'package:prysm/services/sync_coordinator.dart';
import 'package:prysm/services/wake_hint_service.dart';
import 'package:flutter_background/flutter_background.dart';
import 'package:window_manager/window_manager.dart';

TorManager? _globalTorManager;
File? _lockFile;

Future<void> quitApp({TorManager? torManager}) async {
  if (!Platform.isAndroid && !Platform.isIOS) {
    await DetachedChatHost.instance.notifyMainClosing();
    await DetachedChatWindowRegistry.instance.closeAll();
    await DetachedChatHost.instance.stop();
    await TrayService.instance.destroy();
    final tm = torManager ?? _globalTorManager;
    if (tm != null) {
      await tm.stopTor();
    }
    try {
      if (_lockFile != null && await _lockFile!.exists()) {
        await _lockFile!.delete();
      }
    } catch (_) {}
    await windowManager.destroy();
  }
}

Future<bool> _isProcessRunning(int pid) async {
  try {
    if (Platform.isWindows) {
      final result = await Process.run('tasklist', ['/FI', 'PID eq $pid']);
      return (result.stdout as String).contains('$pid');
    } else {
      final result = await Process.run('kill', ['-0', '$pid']);
      return result.exitCode == 0;
    }
  } catch (_) {
    return false;
  }
}

void main(List<String> args) {
  runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      ensureSqflitePlatformInitialized();

      FlutterError.onError = (details) {
        FlutterError.presentError(details);
        Logging.error('FlutterError: ${details.exception}\n${details.stack}', 'Main');
      };
      PlatformDispatcher.instance.onError = (error, stack) {
        Logging.error('Uncaught async error: $error\n$stack', 'Main');
        return true;
      };

      await bootstrapApp(
        isDesktop: isDesktopPlatform,
        readEngineArguments: () async {
          final windowController = await WindowController.fromCurrentEngine();
          return windowController.arguments;
        },
        runMainApp: _runMainApp,
        runDetachedApp: _runDetachedApp,
      );
    },
    (error, stack) {
      Logging.error('Zone error: $error\n$stack', 'Main');
    },
  );
}

Future<void> _runDetachedApp(DetachedChatLaunch launch) async {
  await SettingsService().init();
  runApp(DetachedChatApp(launch: launch));
}

Future<void> _runMainApp() async {
  if (Platform.isAndroid || Platform.isIOS) {
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }

  // Prevent multiple instances on desktop
  if (!Platform.isAndroid && !Platform.isIOS) {
    final docDir = await getApplicationDocumentsDirectory();
    _lockFile = File(p.join(docDir.path, 'prysm', '.lock'));
    await Directory(p.join(docDir.path, 'prysm')).create(recursive: true);

    if (await _lockFile!.exists()) {
      final pidStr = (await _lockFile!.readAsString()).trim();
      final pid = int.tryParse(pidStr);
      if (pid != null && await _isProcessRunning(pid)) {
        // Another instance is running — activate it and exit
        Logging.info('Another instance of Prysm is already running (PID $pid).', 'Main');
        exit(0);
      }
    }
    // Write our PID
    await _lockFile!.writeAsString('$pid');

    TrayService.instance.registerQuitHandler(
      () => quitApp(torManager: _globalTorManager),
    );

    ProcessSignal.sigterm.watch().listen((_) async {
      await quitApp(torManager: _globalTorManager);
    });
    ProcessSignal.sigint.watch().listen((_) async {
      await quitApp(torManager: _globalTorManager);
    });
  }

  await SettingsService().init();
  await PeerTransportRegistry.instance.load();
  await BatterySaverService.instance.init();
  await NotificationMuteService.instance.init();

  String? startupError;
  try {
    await BlockService.instance.init();
  } catch (e, st) {
    Logging.error('BlockService init failed: $e\n$st', 'Main');
    startupError = e.toString();
  }

  final keyManager = KeyManager();

  // Start early so Tor peers can connect during bootstrap / unlock screen.
  final messageServer = PrysmServer(port: 12345, keyManager: keyManager);
  var serverBindFailed = false;
  try {
    await messageServer.start();
  } catch (e, st) {
    Logging.error('PrysmServer start failed: $e\n$st', 'Main');
    serverBindFailed = true;
  }
  LocalOnionAddress.provider = () => PrysmServer.instance?.localOnionAddress;

  runApp(
    MyApp(
      keyManager: keyManager,
      startupError: startupError,
      serverBindFailed: serverBindFailed,
    ),
  );

  if (!Platform.isAndroid && !Platform.isIOS) {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await windowManager.ensureInitialized();
      await windowManager.setTitleBarStyle(TitleBarStyle.normal);
      await windowManager.show();
      await windowManager.focus();
      await TrayService.instance.init();
    });
  }

  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(NotificationService().init());
  });

  // Request notification permissions after runApp so dialogs appear over UI.
  if (Platform.isAndroid || Platform.isIOS || Platform.isMacOS) {
    Future.microtask(() async {
      if (SettingsService().enableNotifications) {
        await NotificationService().requestPermission();
      }
    });
  }

  // Start Android background service AFTER runApp
  if (Platform.isAndroid) {
    Future.microtask(() async {
      final settings = SettingsService();
      final androidConfig = FlutterBackgroundAndroidConfig(
        notificationTitle: "${settings.name} Chat is running",
        notificationText:
            "${settings.name} chat is actively waiting for new messages",
        notificationImportance: AndroidNotificationImportance.normal,
        notificationIcon: AndroidResource(name: "icon", defType: "drawable"),
      );
      try {
        await FlutterBackground.initialize(androidConfig: androidConfig);
        await FlutterBackground.enableBackgroundExecution();
      } catch (_) {
        // Background execution is best-effort; don't crash if denied
      }
    });
  }
}

/// Initializes Tor and the message server in the background.
/// Returns the onion address when ready.
/// Desktop updater check — deferred until after HomeScreen is visible.
Future<void> runDesktopUpdaterCheck() async {
  if (Platform.isAndroid || Platform.isIOS) return;
  try {
    await UpdaterDownloader().getOrDownloadUpdater();
    checkForUpdatesAndLaunchUpdater();
  } catch (e) {
    Logging.error('Error downloading updater: $e', 'Main');
  }
}

Future<String> _resolveTorDataDir() async {
  final documentsDir = await getApplicationDocumentsDirectory();
  final dataDirPath = p.join(
    documentsDir.path,
    'prysm',
    'tor_executable',
    'tor_data',
  );
  final dataDir = Directory(dataDirPath);
  if (!dataDir.existsSync()) {
    dataDir.createSync(recursive: true);
  }
  return dataDirPath;
}

Future<String> _resolveTorBinaryPath({bool allowDownload = true}) async {
  if (Platform.isAndroid) return '';
  if (allowDownload) {
    final torDownloader = TorDownloader();
    return torDownloader.getOrDownloadTor();
  }

  final documentsDir = await getApplicationDocumentsDirectory();
  final torDirPath = p.join(documentsDir.path, 'prysm', 'tor_executable');
  final String executableName;
  if (Platform.isWindows) {
    executableName = 'tor.exe';
  } else if (Platform.isMacOS) {
    executableName = 'tor_macos';
  } else if (Platform.isLinux) {
    executableName = 'tor';
  } else {
    return '';
  }

  final executablePath = p.join(torDirPath, executableName);
  return File(executablePath).existsSync() ? executablePath : '';
}

Future<TorManager> createTorManager({bool allowDownload = true}) async {
  final torPath = await _resolveTorBinaryPath(allowDownload: allowDownload);
  final dataDirPath = await _resolveTorDataDir();
  return TorManager(
    torPath: torPath,
    dataDir: dataDirPath,
    controlPassword: 'your_strong_password_here',
  );
}

Future<String?> loadCachedOnionAddress() async {
  final manager = await createTorManager(allowDownload: false);
  return manager.getCachedOnionAddress();
}

Future<TorInitResult> initializeTor() async {
  TorBootstrapNotifier.instance.reset();
  final torManager = await createTorManager();

  await torManager.startTor();

  final onionAddress = await torManager.getOnionAddress();
  if (onionAddress == null || onionAddress.isEmpty) {
    throw Exception('Failed to create hidden service: no onion address');
  }

  return TorInitResult(torManager: torManager, onionAddress: onionAddress);
}

class TorInitResult {
  final TorManager torManager;
  final String onionAddress;
  const TorInitResult({required this.torManager, required this.onionAddress});
}

Future<bool> isNewerVersion(String current, String latest) async {
  List<int> toNums(String v) =>
      v.replaceFirst('v', '').split('.').map((s) => int.parse(s.replaceAll(RegExp(r'\D.*'), ''))).toList();

  final currNums = toNums(current);
  final latestNums = toNums(latest);
  for (int i = 0; i < currNums.length && i < latestNums.length; i++) {
    if (latestNums[i] > currNums[i]) return true;
    if (latestNums[i] < currNums[i]) return false;
  }
  return latestNums.length > currNums.length;
}

const String currentVersion = SettingsService.appVersion;

Future<void> checkForUpdatesAndLaunchUpdater() async {
  final url = Uri.parse(
    'https://api.github.com/repos/xmreur/prysm/releases/latest',
  );

  try {
    final response = await http.get(url);
    if (response.statusCode == 200) {
      final jsonData = jsonDecode(response.body);

      final latestVersion = jsonData['tag_name'] as String;

      if (await isNewerVersion(currentVersion, latestVersion)) {
        final updaterPath = await UpdaterDownloader().getOrDownloadUpdater();

        Logging.info('Launching updater process...', 'Main');
        await Process.start(updaterPath, [], mode: ProcessStartMode.detached);

        // Exit app to allow updater to proceed
        exit(0);
      } else {
        Logging.info('Already at latest version $currentVersion', 'Main');
      }
    } else {
      Logging.warning(
        'Failed to fetch latest release info. Status: ${response.statusCode}',
        'Main',
      );
    }
  } catch (e) {
    Logging.error('Error checking updates: $e', 'Main');
  }
}

class MyWindowListener extends WindowListener {
  final TorManager torManager;
  MyWindowListener(this.torManager);

  @override
  void onWindowClose() async {
    if (CallForegroundSession.isActive) {
      await windowManager.hide();
      return;
    }
    if (TrayService.instance.isEnabled) {
      await windowManager.hide();
      return;
    }
    await quitApp(torManager: torManager);
  }

  @override
  void onWindowMinimize() async {
    if (TrayService.instance.shouldMinimizeOnMinimizeButton) {
      await windowManager.hide();
    }
  }
}

class MyApp extends StatefulWidget {
  final KeyManager keyManager;
  final String? startupError;
  final bool serverBindFailed;

  const MyApp({
    required this.keyManager,
    this.startupError,
    this.serverBindFailed = false,
    super.key,
  });

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  static final settings = SettingsService();

  bool unlocked = false;
  bool _keysChecked = false;
  bool _keysExist = false;
  bool _needsMigration = false;
  bool _migrationChecked = false;
  String? _startupError;
  bool _panicDecoySession = false;
  int _currentTheme = 0;

  // Tor init state
  TorManager? _torManager;
  String? _onionAddress;
  String _torStatus = 'Initializing...';
  bool _torReady = false;
  bool _torFailed = false;
  bool _offlineMode = false;
  bool _torConnecting = false;
  int _torBootstrapProgress = 0;
  StreamSubscription<int>? _bootstrapSub;

  @override
  void dispose() {
    _bootstrapSub?.cancel();
    super.dispose();
  }

  Future<bool> onVerifyUnlock(String secret) async {
    final keyManager = widget.keyManager;
    final lockout = UnlockLockoutService.instance;
    final type = settings.unlockType;

    if (!await lockout.isLockedOut()) {
      if (await keyManager.unlockWithPassphrase(secret, type: type)) {
        await lockout.recordSuccess();
        await settings.migrateOnboardingIfExisting(
          readPublicKey: () =>
              keyManager.safeRead(CryptoKeyStore.publicIdentityKey),
          contactCount: (await DBHelper.getUsers()).length,
        );
        if (!mounted) return true;
        setState(() {
          unlocked = true;
          _keysExist = true;
          _panicDecoySession = false;
        });
        return true;
      }
      await lockout.recordPrimaryFailure();
    }

    if (secret.length == 6 &&
        await PanicPinService.instance.isConfigured() &&
        await PanicPinService.instance.verify(secret)) {
      await lockout.recordSuccess();
      if (settings.panicAction == PanicAction.wipe) {
        await PanicWipeService.wipeAll();
        await keyManager.wipeSecureStorage();
        await settings.load();
      } else {
        keyManager.lock();
      }
      await keyManager.loadEphemeralKeys();
      if (!mounted) return true;
      setState(() {
        unlocked = true;
        _keysExist = true;
        _panicDecoySession = true;
      });
      return true;
    }

    return false;
  }

  Future<bool> onVerifyPassphrase(String passphrase) =>
      onVerifyUnlock(passphrase);

  Future<bool> onVerifyPin(String pin) => onVerifyUnlock(pin);

  @override
  void initState() {
    super.initState();
    _startupError = widget.startupError;
    _loadSavedTheme();
    _checkMigration();
    _checkKeysExist();
    unawaited(Logging.init());
    _bootstrapSub = TorBootstrapNotifier.instance.onProgress.listen((p) {
      if (mounted) setState(() => _torBootstrapProgress = p);
    });
    unawaited(_checkStartupConnectivity());
  }

  Future<void> _checkStartupConnectivity() async {
    if (!await NetworkReachability.hasInternet()) {
      await _enterOfflineMode();
      return;
    }
    await _initTorInBackground();
  }

  Future<void> _enterOfflineMode() async {
    final manager = await createTorManager(allowDownload: false);
    final cachedOnion = await manager.getCachedOnionAddress();
    if (!mounted) return;
    setState(() {
      _torManager = manager;
      _onionAddress = cachedOnion;
      _offlineMode = true;
      _torReady = false;
      _torFailed = false;
      _torConnecting = false;
      _torStatus = cachedOnion == null || cachedOnion.isEmpty
          ? 'Offline — connect to Tor to get your Prysm ID'
          : 'Offline';
    });
    TorConnectionNotifier.instance.update(TorConnectionState.disconnected);
  }

  Future<void> _applyTorConnectedResult(TorInitResult result) async {
    _globalTorManager = result.torManager;
    TransportProvider.configure(result.torManager);
    CallManager.configure(keyManager: widget.keyManager);
    CallManager.instance.start();

    if (!Platform.isAndroid && !Platform.isIOS) {
      windowManager.addListener(MyWindowListener(result.torManager));
    }

    PrysmServer.instance?.localOnionAddress = result.onionAddress;
    TorConnectionNotifier.instance.update(TorConnectionState.connected);
  }

  Future<void> _connectTor() async {
    if (_torConnecting) return;
    if (!await NetworkReachability.hasInternet()) {
      if (mounted) {
        setState(() {
          _torFailed = true;
          _torStatus = 'No internet connection detected.';
        });
      }
      return;
    }

    setState(() {
      _torConnecting = true;
      _torFailed = false;
      _torReady = false;
      _torStatus = 'Connecting to Tor...';
    });

    try {
      final result = await initializeTor();
      await _applyTorConnectedResult(result);
      if (mounted) {
        setState(() {
          _torManager = result.torManager;
          _onionAddress = result.onionAddress;
          _torReady = true;
          _offlineMode = false;
          _torConnecting = false;
          _torFailed = false;
          _torStatus = 'Connected';
        });
      }
    } catch (e) {
      Logging.error('Tor connection failed: $e', 'Main');
      if (_torManager == null) {
        await _enterOfflineMode();
      }
      if (mounted) {
        setState(() {
          _torConnecting = false;
          _torFailed = true;
          _offlineMode = true;
          _torStatus =
              'Failed to connect to Tor. Check your network and try again.';
        });
        TorConnectionNotifier.instance.update(TorConnectionState.disconnected);
      }
    }
  }

  Future<void> _checkKeysExist() async {
    final exists = await widget.keyManager.isPassphraseSet();
    if (!mounted) return;
    setState(() {
      _keysExist = exists;
      _keysChecked = true;
    });
  }

  Future<void> _checkMigration() async {
    final needs = await CryptoKeyStore.needsCryptoMigration();
    if (mounted) {
      setState(() {
        _needsMigration = needs;
        _migrationChecked = true;
      });
    }
  }

  Future<void> _initTorInBackground() async {
    try {
      setState(() => _torStatus = 'Starting Tor...');
      final result = await initializeTor();
      await _applyTorConnectedResult(result);

      if (mounted) {
        setState(() {
          _torManager = result.torManager;
          _onionAddress = result.onionAddress;
          _torReady = true;
          _offlineMode = false;
          _torFailed = false;
          _torConnecting = false;
          _torStatus = 'Connected';
        });
      }
    } catch (e) {
      Logging.error('Tor initialization failed: $e', 'Main');
      if (mounted) {
        setState(() {
          _torFailed = true;
          _torConnecting = false;
          _torStatus =
              'Failed to connect to Tor. Check your network and try again.';
        });
        TorConnectionNotifier.instance.update(TorConnectionState.disconnected);
      }
    }
  }

  Future<void> _retryTor() async {
    setState(() {
      _torFailed = false;
      _torReady = false;
      _offlineMode = false;
      _torStatus = 'Retrying Tor connection...';
    });
    await _connectTor();
  }

  Future<void> _loadSavedTheme() async {
    final themeIndex = settings.themeMode;
    setState(() {
      _currentTheme = themeIndex;
    });
  }

  void updateTheme(int themeIndex) async {
    setState(() {
      _currentTheme = themeIndex;
    });
    await settings.setThemeMode(themeIndex);
  }

  void updateAppearance() {
    // Style refresh is driven by SettingsService.styleRevision.
  }

  Widget _prysmApp({required Widget home, String? title}) {
    return PrysmApp(
      key: const ValueKey('prysm_app_root'),
      themePalette: _currentTheme,
      appearance: settings.appearance,
      title: title,
      home: home,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_startupError != null) {
      return _prysmApp(
        home: StartupFatalErrorScreen(
          error: _startupError!,
          keyManager: widget.keyManager,
          onResetComplete: () => setState(() => _startupError = null),
        ),
      );
    }

    if (!_migrationChecked) {
      return _prysmApp(
        home: const PrysmPage(body: Center(child: PrysmProgressIndicator())),
      );
    }

    if (_needsMigration) {
      return _prysmApp(
        home: CryptoMigrationScreen(
          keyManager: widget.keyManager,
          onComplete: () => setState(() {
            _needsMigration = false;
          }),
        ),
      );
    }

    if (!_keysChecked) {
      return _prysmApp(
        home: const PrysmPage(body: Center(child: PrysmProgressIndicator())),
      );
    }

    if (!_keysExist) {
      return _prysmApp(
        title: "Setup ${settings.name}",
        home: OnboardingScreen(
          isInitialSetup: true,
          keyManager: widget.keyManager,
          onionAddress: _onionAddress ?? '',
          torReady: _torReady,
          offlineMode: _offlineMode,
          torBootstrapProgress: _torBootstrapProgress > 0
              ? _torBootstrapProgress
              : null,
          onComplete: () {
            if (mounted) {
              setState(() {
                _keysExist = true;
                unlocked = true;
              });
            }
          },
        ),
      );
    }

    if (!unlocked) {
      return _prysmApp(
        title: "Unlock ${settings.name} Chat",
        home: UnlockScreen(
          usePin: settings.unlockType == UnlockType.pin,
          onVerify: onVerifyUnlock,
          isUnlockSet: widget.keyManager.isPassphraseSet(),
          torBootstrapProgress: _torBootstrapProgress > 0
              ? _torBootstrapProgress
              : null,
        ),
      );
    }
    if (!_torReady && !_offlineMode) {
      return _prysmApp(
        title: '${settings.name} Chat',
        home: PrysmPage(
          body: Builder(
            builder: (ctx) {
              final tokens = ctx.prysmStyle.tokens;
              return Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (_torFailed)
                      Icon(
                        PrysmIcons.wifiOff,
                        size: 48,
                        color: tokens.danger,
                      )
                    else
                      const PrysmProgressIndicator(),
                    const SizedBox(height: 24),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 32),
                      child: Text(
                        _torStatus,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _torFailed
                          ? 'You can use Prysm offline or retry when you have a connection.'
                          : _torBootstrapProgress > 0
                          ? 'Tor bootstrap: $_torBootstrapProgress%'
                          : 'Setting up secure connection...',
                      style: TextStyle(
                        fontSize: 13,
                        color: tokens.textMuted,
                      ),
                    ),
                    if (!_torFailed && _torBootstrapProgress > 0) ...[
                      const SizedBox(height: 12),
                      SizedBox(
                        width: 200,
                        height: 4,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: tokens.outline,
                            borderRadius: BorderRadius.circular(2),
                          ),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: FractionallySizedBox(
                              widthFactor:
                                  (_torBootstrapProgress / 100).clamp(0.0, 1.0),
                              heightFactor: 1,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: tokens.accent,
                                  borderRadius: BorderRadius.circular(2),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                    if (_torFailed) ...[
                      const SizedBox(height: 24),
                      PrysmButton(
                        label: 'Retry',
                        onPressed: _retryTor,
                      ),
                      const SizedBox(height: 12),
                      PrysmButton(
                        label: 'Continue offline',
                        variant: PrysmButtonVariant.secondary,
                        onPressed: _enterOfflineMode,
                      ),
                    ],
                  ],
                ),
              );
            },
          ),
        ),
      );
    }
    final onionAddress = _panicDecoySession
        ? DecoySessionData.identityOnion
        : (_onionAddress ?? '');
    final showOnboarding = !_panicDecoySession && !settings.onboardingCompleted;

    return _prysmApp(
      title: '${settings.name} Chat',
      home: showOnboarding
          ? OnboardingScreen(
              onionAddress: onionAddress,
              torReady: _torReady,
              offlineMode: _offlineMode,
              onComplete: () {
                if (mounted) setState(() {});
              },
            )
          : CallOverlay(
              child: HomeScreen(
                torManager: _torManager!,
                onionAddress: onionAddress,
                keyManager: widget.keyManager,
                onThemeChanged: updateTheme,
                onAppearanceChanged: updateAppearance,
                currentTheme: _currentTheme,
                decoyMode: _panicDecoySession,
                offlineMode: _offlineMode,
                torConnecting: _torConnecting,
                onConnectTor: _connectTor,
              ),
            ),
    );
  }
}

class HomeScreen extends StatefulWidget {
  final TorManager torManager;
  final String onionAddress;
  final KeyManager keyManager;
  final Function(int)? onThemeChanged;
  final VoidCallback? onAppearanceChanged;
  final int currentTheme;
  final bool decoyMode;
  final bool offlineMode;
  final bool torConnecting;
  final Future<void> Function() onConnectTor;

  const HomeScreen({
    required this.torManager,
    required this.onionAddress,
    required this.keyManager,
    required this.onConnectTor,
    this.onThemeChanged,
    this.onAppearanceChanged,
    this.currentTheme = 0,
    this.decoyMode = false,
    this.offlineMode = false,
    this.torConnecting = false,
    super.key,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  static final settings = SettingsService();

  List<Contact> contacts = [];
  List<Group> groups = [];
  List<Conversation> conversations = [];
  late Contact appUser;
  Contact? selectedContact;
  Conversation? selectedConversation;
  bool showProfile = false;
  bool showSettings = false;
  bool showSelfChat = false;
  int? _selfChatLastTimestamp;
  String? _selfChatLastPreview;
  bool isLoading = true;
  int currentTheme =
      0; // 0: Light, 1: Dark, 2: Pink, 3: Cyan, 4: Purple, 5 Orange
  String _searchQuery = '';
  final _searchController = TextEditingController();
  Map<String, String> _lastMessagePreviews = {};
  Map<String, int> _unreadCounts = {};
  Map<String, ConversationPreferences> _conversationPrefs = {};
  Map<String, List<DecoyMessage>> _decoyMessages = {};
  bool _viewingArchived = false;
  bool _viewingBlocked = false;
  bool _sidebarOpen = false;

  Timer? _refreshTimer;
  Timer? _loadUsersDebounce;
  StreamSubscription<void>? _batterySaverSub;
  StreamSubscription<void>? _inboundRefreshSub;
  StreamSubscription<String>? _groupMembershipSub;
  SyncCoordinator? _syncCoordinator;
  TorSupervisor? _torSupervisor;
  bool _loadUsersInProgress = false;
  bool _loadUsersQueued = false;
  bool _loadUsersQueuedLight = false;

  int get _archivedCount => conversations
      .where((c) => _conversationPrefs[c.id]?.isArchived ?? false)
      .length;

  int get _archivedUnreadCount => conversations
      .where(
        (c) =>
            (_conversationPrefs[c.id]?.isArchived ?? false) &&
            (_unreadCounts[c.id] ?? 0) > 0,
      )
      .length;

  int get _blockedCount => conversations
      .where(
        (c) => c is DirectConversation && BlockService.instance.isBlocked(c.id),
      )
      .length;

  int get _sidebarFooterCount {
    if (_viewingArchived || _viewingBlocked || _searchQuery.isNotEmpty) {
      return 0;
    }
    var count = 0;
    if (_archivedCount > 0) count++;
    if (_blockedCount > 0) count++;
    return count;
  }

  List<Conversation> get _filteredConversations {
    return conversations.where((c) {
      final blocked =
          c is DirectConversation && BlockService.instance.isBlocked(c.id);
      final archived = _conversationPrefs[c.id]?.isArchived ?? false;

      if (_viewingBlocked) {
        if (!blocked) return false;
        if (_searchQuery.isNotEmpty) {
          final name = c.contact.displayName.toLowerCase();
          return name.contains(_searchQuery) ||
              c.id.toLowerCase().contains(_searchQuery);
        }
        return true;
      }

      if (blocked) return false;

      if (_searchQuery.isNotEmpty) {
        if (!c.displayName.toLowerCase().contains(_searchQuery)) return false;
        return _viewingArchived ? archived : true;
      }
      return _viewingArchived ? archived : !archived;
    }).toList();
  }

  Future<void> _reloadConversationPreferences() async {
    if (widget.decoyMode) return;
    final prefs = await ConversationPreferencesService.instance.getAll();
    if (!mounted) return;
    setState(() {
      _conversationPrefs = prefs;
      ConversationPreferencesService.sortConversations(conversations, prefs);
    });
  }

  void _updateDecoyConversationPref(ConversationPreferences pref) {
    setState(() {
      _conversationPrefs = Map.of(_conversationPrefs)
        ..[pref.conversationId] = pref;
      ConversationPreferencesService.sortConversations(
        conversations,
        _conversationPrefs,
      );
    });
  }

  Future<void> _pinConversation(String id) async {
    if (widget.decoyMode) {
      _updateDecoyConversationPref(
        ConversationPreferences(
          conversationId: id,
          isPinned: true,
          pinnedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      return;
    }
    await ConversationPreferencesService.instance.pin(id);
    await _reloadConversationPreferences();
  }

  Future<void> _unpinConversation(String id) async {
    if (widget.decoyMode) {
      _updateDecoyConversationPref(ConversationPreferences(conversationId: id));
      return;
    }
    await ConversationPreferencesService.instance.unpin(id);
    await _reloadConversationPreferences();
  }

  Future<void> _archiveConversation(String id) async {
    if (widget.decoyMode) {
      _updateDecoyConversationPref(
        ConversationPreferences(
          conversationId: id,
          isArchived: true,
          archivedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      if (selectedConversation?.id == id) {
        clearChat();
      }
      if (mounted) {
        setState(() => _viewingArchived = false);
      }
      return;
    }
    await ConversationPreferencesService.instance.archive(id);
    if (selectedConversation?.id == id) {
      clearChat();
    }
    if (mounted) {
      setState(() => _viewingArchived = false);
    }
    await _reloadConversationPreferences();
  }

  Future<void> _unarchiveConversation(String id) async {
    if (widget.decoyMode) {
      _updateDecoyConversationPref(ConversationPreferences(conversationId: id));
      return;
    }
    await ConversationPreferencesService.instance.unarchive(id);
    await _reloadConversationPreferences();
  }

  void _showConversationActions(Conversation conv) {
    showConversationActionsSheet(
      context: context,
      conversation: conv,
      preferences: _conversationPrefs[conv.id],
      viewingArchived: _viewingArchived,
      onPin: () => _pinConversation(conv.id),
      onUnpin: () => _unpinConversation(conv.id),
      onArchive: () => _archiveConversation(conv.id),
      onUnarchive: () => _unarchiveConversation(conv.id),
    );
  }

  void _wireOnlineServices() {
    if (widget.decoyMode || widget.offlineMode) return;

    TransportProvider.configure(
      widget.torManager,
      onPeerConnected: (peerId) =>
          _syncCoordinator!.flushPendingForPeer(peerId),
    );
    TransportProvider.instance.startWebSocketConnections();
    FileTransferHandler.instance.start();
    TorRuntimeGate.isTorStopped = () => _torStopped;
    if (!Platform.isAndroid && !Platform.isIOS) {
      _torSupervisor = TorSupervisor(
        torManager: widget.torManager,
        isTorStopped: () => _torStopped,
        isRestartInProgress: () => _torRestartInProgress,
        performRestart: ({bool userInitiated = false}) =>
            _performTorRestart(userInitiated: userInitiated),
      );
    }
    _syncCoordinator!.start();
    WakeHintService.instance.configure(
      userId: widget.onionAddress,
      onFlushPeer: (peerId) => _syncCoordinator!.flushPendingForPeer(peerId),
    );
    ReadReceiptService.configure(
      flushPendingForPeer: (peerId) =>
          _syncCoordinator!.flushPendingForPeer(peerId),
    );
    _torStopped = false;
    TorLifecycleNotifier.instance.update(TorLifecycleState.ready);
    _torConnectionState = TorConnectionState.disconnected;
    _startTorHealthMonitor();
    unawaited(_onTorReconnected());
  }

  @override
  void didUpdateWidget(HomeScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.offlineMode && !widget.offlineMode) {
      _wireOnlineServices();
      unawaited(loadUsers());
    }
    if (oldWidget.currentTheme != widget.currentTheme) {
      setState(() {
        currentTheme = widget.currentTheme;
      });
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    currentTheme = widget.currentTheme;
    final appSettings = SettingsService();
    if (widget.decoyMode) {
      _bootstrapDecoySession();
    } else {
      appUser = Contact(
        id: widget.onionAddress,
        name: appSettings.username ?? '',
        avatarUrl: '',
        identityJson: 'NONE',
      );
    }
    if (widget.offlineMode) {
      _torStopped = true;
      TorLifecycleNotifier.instance.update(TorLifecycleState.stopped);
      _torConnectionState = TorConnectionState.disconnected;
      TorConnectionNotifier.instance.update(TorConnectionState.disconnected);
    }
    _syncCoordinator = SyncCoordinator(
      userId: widget.decoyMode ? 'decoy-user' : widget.onionAddress,
      keyManager: widget.keyManager,
      torManager: widget.torManager,
      isTorStopped: () => _torStopped,
    );
    if (!widget.decoyMode && !widget.offlineMode) {
      _wireOnlineServices();
    } else if (!widget.decoyMode) {
      TorRuntimeGate.isTorStopped = () => _torStopped;
    }

    if (widget.decoyMode) {
      return;
    }

    loadUsers()
        .then((_) async {
          if (mounted && !_torStopped) {
            final flushed = await _syncCoordinator!.flushAllPending();
            if (flushed && mounted) {
              scheduleLoadUsers(light: true);
            }
            if (mounted) {
              unawaited(_maybeBroadcastWakeHints(coldStart: true));
            }
          }
        })
        .catchError((Object e, StackTrace st) {
          Logging.error('loadUsers failed: $e\n$st', 'Main');
        });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(runDesktopUpdaterCheck());
    });

    _startAutoRefresh();
    if (!widget.offlineMode) {
      _startTorHealthMonitor();
    }
    _batterySaverSub = BatterySaverService.instance.onChanged.listen((_) {
      if (!mounted) return;
      _restartBackgroundIntervals();
    });
    _inboundRefreshSub = ConversationRefreshNotifier.instance.onRefresh.listen((
      _,
    ) {
      scheduleLoadUsers(light: true);
    });
    _groupMembershipSub = GroupMembershipNotifier.instance.onRemoved.listen((
      groupId,
    ) {
      if (!mounted) return;
      if (selectedConversation is GroupConversation &&
          (selectedConversation as GroupConversation).group.id == groupId) {
        clearChat();
      }
      scheduleLoadUsers(light: true);
    });
    NotificationService.onNotificationTap = _handleNotificationTap;
    NotificationService.onCallNotificationTap = _handleCallNotificationAction;

    if (!Platform.isAndroid && !Platform.isIOS) {
      unawaited(TrayService.instance.start(userId: widget.onionAddress));
      _configureDetachedChat();
    }
  }

  void _configureDetachedChat() {
    if (!isDesktopPlatform || widget.decoyMode || widget.offlineMode) {
      DetachedChatWindowRegistry.instance.setCanOpen(false);
      return;
    }
    DetachedChatWindowRegistry.instance.setCanOpen(true);
    DetachedChatBridge.configure(
      keyManager: widget.keyManager,
      userId: widget.onionAddress,
      appUser: () => appUser,
      contacts: () => contacts,
      groupById: (groupId) {
        try {
          return groups.firstWhere((g) => g.id == groupId);
        } catch (_) {
          return null;
        }
      },
    );
    unawaited(DetachedChatHost.instance.start());
  }

  bool get _canOpenDetachedChat =>
      isDesktopPlatform &&
      !widget.decoyMode &&
      !widget.offlineMode &&
      !_torStopped &&
      TransportProvider.isConfigured;

  Future<void> _openDetachedFromConversation(Conversation conv) async {
    if (!_canOpenDetachedChat) return;

    final launch = switch (conv) {
      DirectConversation(:final contact) => DetachedChatLaunch.detached(
        chatKind: DetachedChatKind.direct,
        conversationId: contact.id,
        title: contact.displayName,
        userId: appUser.id,
        userName: appUser.name,
        avatarBase64: contact.avatarBase64,
        peerPublicKeyPem: contact.publicKeyPem,
        themeIndex: currentTheme,
      ),
      GroupConversation(:final group) => DetachedChatLaunch.detached(
        chatKind: DetachedChatKind.group,
        conversationId: group.id,
        title: group.name,
        userId: appUser.id,
        userName: appUser.name,
        avatarBase64: group.avatarBase64,
        themeIndex: currentTheme,
      ),
      SelfConversation() => throw UnsupportedError(
        'Self chat uses dedicated handler',
      ),
    };

    try {
      await DetachedChatWindowRegistry.instance.openOrFocus(launch);
    } catch (e) {
      if (!mounted) return;
      showPrysmToast(context, 'Could not open separate window: $e');
    }
  }

  Future<void> _openDetachedSelfChat() async {
    if (!_canOpenDetachedChat) return;
    final launch = DetachedChatLaunch.detached(
      chatKind: DetachedChatKind.self,
      conversationId: DetachedChatLaunch.selfConversationId,
      title: 'Chat with myself',
      userId: appUser.id,
      userName: appUser.name,
      avatarBase64: appUser.avatarBase64,
      themeIndex: currentTheme,
    );
    try {
      await DetachedChatWindowRegistry.instance.openOrFocus(launch);
    } catch (e) {
      if (!mounted) return;
      showPrysmToast(context, 'Could not open separate window: $e');
    }
  }

  void _showConversationContextMenu(Offset position, Conversation conv) {
    showConversationContextMenu(
      context: context,
      position: position,
      conversation: conv,
      preferences: _conversationPrefs[conv.id],
      viewingArchived: _viewingArchived,
      canOpenDetached: _canOpenDetachedChat,
      onOpenDetached: () => _openDetachedFromConversation(conv),
      onPin: () => _pinConversation(conv.id),
      onUnpin: () => _unpinConversation(conv.id),
      onArchive: () => _archiveConversation(conv.id),
      onUnarchive: () => _unarchiveConversation(conv.id),
    );
  }

  void scheduleLoadUsers({bool light = false}) {
    _loadUsersQueuedLight = _loadUsersQueuedLight || light;
    _loadUsersDebounce?.cancel();
    _loadUsersDebounce = Timer(BatterySaverPolicy.loadUsersDebounce(), () {
      if (!mounted) return;
      final lightOnly = _loadUsersQueuedLight;
      _loadUsersQueuedLight = false;
      unawaited(loadUsers(light: lightOnly));
    });
  }

  void _handleNotificationTap(String? payload) {
    unawaited(_openChatFromNotificationPayload(payload));
  }

  void _handleCallNotificationAction(PendingCallAction action) {
    unawaited(_processCallNotificationAction(action));
  }

  Future<void> _processCallNotificationAction(PendingCallAction action) async {
    if (widget.decoyMode) return;
    if (!mounted) {
      PendingCallActionStore.instance.set(action);
      return;
    }

    try {
      CallManager.instance;
    } catch (_) {
      PendingCallActionStore.instance.set(action);
      return;
    }

    try {
      switch (action.action) {
        case CallNotificationAction.accept:
          if (CallManager.instance.snapshot.state != CallState.incoming) break;
          await NotificationService().cancelCallNotifications();
          await CallManager.instance.acceptIncoming();
        case CallNotificationAction.decline:
          await NotificationService().cancelCallNotifications();
          await CallManager.instance.declineFromNotification(
            callId: action.callId,
            peerOnion: action.peerOnion,
          );
        case CallNotificationAction.hangup:
          if (!CallManager.instance.snapshot.isInCall) break;
          await NotificationService().cancelCallNotifications();
          await CallManager.instance.endCall();
        case CallNotificationAction.open:
          break;
      }
    } finally {
      PendingCallActionStore.instance.clear();
    }
  }

  Future<void> _consumePendingCallAction() async {
    final action = PendingCallActionStore.instance.take();
    if (action == null) return;
    await _processCallNotificationAction(action);
  }

  Future<void> _openChatFromNotificationPayload(String? payload) async {
    if (widget.decoyMode || !mounted) return;

    final route = payload != null
        ? PendingNotificationRoute.fromPayload(payload)
        : PendingNotificationRouteStore.instance.take();
    if (payload != null) {
      PendingNotificationRouteStore.instance.clear();
    }
    if (route == null) return;

    if (route.isGroup) {
      final group = await NotificationOpenChatResolver.resolveGroup(
        groups: groups,
        groupId: route.groupId!,
      );
      if (!mounted || group == null) return;
      onSelectGroup(group);
      await NotificationService().cancelConversationNotification(
        groupId: route.groupId,
        senderId: route.senderId,
      );
      _closeMobileDrawerIfOpen();
      return;
    }

    final contact = await NotificationOpenChatResolver.resolveContact(
      contacts: contacts,
      senderId: route.senderId,
    );
    if (!mounted || contact == null) return;
    onSelectContact(contact);
    await NotificationService().cancelConversationNotification(
      senderId: route.senderId,
    );
    _closeMobileDrawerIfOpen();
  }

  Future<void> _consumePendingNotificationRoute() async {
    if (PendingNotificationRouteStore.instance.peek() == null) return;
    await _openChatFromNotificationPayload(null);
  }

  void _closeMobileDrawerIfOpen() {
    if (!mounted) return;
    if (MediaQuery.of(context).size.width >= 600) return;
    if (_sidebarOpen) {
      setState(() => _sidebarOpen = false);
    }
  }

  void _dismissConversationNotification({
    String? groupId,
    required String senderId,
  }) {
    unawaited(
      NotificationService().cancelConversationNotification(
        groupId: groupId,
        senderId: senderId,
      ),
    );
  }

  void _syncActiveConversationTracker() {
    if (widget.decoyMode) {
      ActiveConversationTracker.instance.clear();
      return;
    }
    final selected = selectedConversation;
    if (selected is DirectConversation) {
      ActiveConversationTracker.instance.setDirect(selected.contact.id);
      return;
    }
    if (selected is GroupConversation) {
      ActiveConversationTracker.instance.setGroup(selected.group.id);
      return;
    }
    ActiveConversationTracker.instance.clear();
  }

  void _restartBackgroundIntervals() {
    _refreshTimer?.cancel();
    _startAutoRefresh();
    if (!widget.offlineMode) {
      _startTorHealthMonitor();
    }
    _syncCoordinator?.start();
  }

  void _startAutoRefresh() {
    _refreshTimer?.cancel();
    _refreshTimer = Timer.periodic(BatterySaverPolicy.homeRefreshInterval(), (
      timer,
    ) async {
      if (!mounted || _torStopped) return;
      await loadUsers();
      if (!mounted || _torStopped) return;
      await _flushPendingIfReachable();
    });
  }

  Future<void> _flushPendingIfReachable() async {
    if (!mounted || _torStopped) return;
    final flushed = await _syncCoordinator?.flushAllPending() ?? false;
    if (flushed && mounted) {
      scheduleLoadUsers(light: true);
    }
  }

  Future<void> loadUsers({bool light = false}) async {
    if (!mounted || widget.decoyMode) return;
    if (_loadUsersInProgress) {
      _loadUsersQueued = true;
      _loadUsersQueuedLight = _loadUsersQueuedLight || light;
      return;
    }
    _loadUsersInProgress = true;

    try {
      final groupService = GroupService(
        userId: widget.onionAddress,
        keyManager: widget.keyManager,
      );
      await groupService.pruneOrphanedGroups();
      await groupService.discardPendingHistoryRelay();

      late final List<Map<String, dynamic>> userMaps;
      late final Map<String, int> timestamps;
      late final List<Group> newGroups;
      late final Map<String, ConversationPreferences> prefs;
      Map<String, String> previews = _lastMessagePreviews;
      Map<String, int> unread = _unreadCounts;

      if (light) {
        final results = await Future.wait([
          DBHelper.getUsers(),
          MessagesDb.getLastMessageTimestampsForAllUsers(),
          groupService.getGroups(),
          MessagesDb.getLastMessagePreviews(widget.onionAddress),
          MessagesDb.getUnreadCounts(widget.onionAddress),
          ConversationPreferencesService.instance.getAll(),
          SelfMessagesDb.getLastTimestamp(),
          SelfMessagesDb.getLastPreview(),
        ]);
        if (!mounted) return;
        userMaps = results[0] as List<Map<String, dynamic>>;
        timestamps = results[1] as Map<String, int>;
        newGroups = results[2] as List<Group>;
        previews = results[3] as Map<String, String>;
        unread = results[4] as Map<String, int>;
        prefs = results[5] as Map<String, ConversationPreferences>;
        _selfChatLastTimestamp = results[6] as int?;
        _selfChatLastPreview = results[7] as String?;
      } else {
        final fastResults = await Future.wait([
          DBHelper.getUsers(),
          MessagesDb.getLastMessageTimestampsForAllUsers(),
          groupService.getGroups(),
          ConversationPreferencesService.instance.getAll(),
        ]);
        if (!mounted) return;
        userMaps = fastResults[0] as List<Map<String, dynamic>>;
        timestamps = fastResults[1] as Map<String, int>;
        newGroups = fastResults[2] as List<Group>;
        prefs = fastResults[3] as Map<String, ConversationPreferences>;

        if (isLoading) {
          _applyLoadedUsers(
            userMaps: userMaps,
            timestamps: timestamps,
            newGroups: newGroups,
            previews: previews,
            unread: unread,
            prefs: prefs,
          );
        }

        final deferred = await Future.wait([
          MessagesDb.getLastMessagePreviews(widget.onionAddress),
          MessagesDb.getUnreadCounts(widget.onionAddress),
          SelfMessagesDb.getLastTimestamp(),
          SelfMessagesDb.getLastPreview(),
        ]);
        if (!mounted) return;
        previews = deferred[0] as Map<String, String>;
        unread = deferred[1] as Map<String, int>;
        _selfChatLastTimestamp = deferred[2] as int?;
        _selfChatLastPreview = deferred[3] as String?;
      }

      _applyLoadedUsers(
        userMaps: userMaps,
        timestamps: timestamps,
        newGroups: newGroups,
        previews: previews,
        unread: unread,
        prefs: prefs,
      );
    } finally {
      _loadUsersInProgress = false;
      if (_loadUsersQueued && mounted) {
        _loadUsersQueued = false;
        final queuedLight = _loadUsersQueuedLight;
        _loadUsersQueuedLight = false;
        scheduleLoadUsers(light: queuedLight);
      }
    }
  }

  void _applyLoadedUsers({
    required List<Map<String, dynamic>> userMaps,
    required Map<String, int> timestamps,
    required List<Group> newGroups,
    required Map<String, String> previews,
    required Map<String, int> unread,
    required Map<String, ConversationPreferences> prefs,
  }) {
    if (!mounted) return;

    final newContacts = <Contact>[];
    for (var map in userMaps) {
      final id = map['id'] as String;
      newContacts.add(
        Contact(
          id: id,
          name: map['name'] as String,
          avatarUrl: '',
          avatarBase64: map['avatarBase64'] as String?,
          customName: map['customName'] as String?,
          identityJson:
              (map['identityJson'] as String?) ??
              (map['publicKeyPem'] as String?) ??
              '',
          lastMessageTimestamp: timestamps[id],
        ),
      );
    }

    Contact? newAppUser;
    try {
      newAppUser = newContacts.firstWhere((c) => c.id == widget.onionAddress);
    } catch (_) {
      saveAppUser(appUser);
    }

    if (newAppUser != null) {
      final s = SettingsService();
      if (s.username == null &&
          newAppUser.name.isNotEmpty &&
          newAppUser.name != 'My Profile') {
        s.setUsername(newAppUser.name);
      }
      if (s.avatar == null && newAppUser.avatarBase64 != null) {
        s.setAvatar(newAppUser.avatarBase64);
      }
    }

    final newConversations = <Conversation>[
      ...newContacts
          .where((c) => c.id != widget.onionAddress)
          .map((c) => DirectConversation(c)),
      ...newGroups.map((g) => GroupConversation(g)),
    ];
    ConversationPreferencesService.sortConversations(newConversations, prefs);

    final changed =
        newContacts.length != contacts.length ||
        newGroups.length != groups.length ||
        !_mapsEqual(previews, _lastMessagePreviews) ||
        !_mapsEqual(unread, _unreadCounts) ||
        !_conversationPrefsEqual(prefs, _conversationPrefs) ||
        !newConversations.every((c) {
          final old = conversations.cast<Conversation?>().firstWhere(
            (o) => o!.id == c.id,
            orElse: () => null,
          );
          return old != null &&
              old.displayName == c.displayName &&
              formatLastMessageTime(old.lastMessageTimestamp) ==
                  formatLastMessageTime(c.lastMessageTimestamp);
        });

    if (changed) {
      setState(() {
        _lastMessagePreviews = previews;
        _unreadCounts = unread;
        _conversationPrefs = prefs;
        contacts = newContacts;
        groups = newGroups;
        conversations = newConversations;
        if (newAppUser != null) {
          appUser = newAppUser;
        }
        if (selectedConversation != null) {
          if (selectedConversation is DirectConversation) {
            final id = (selectedConversation as DirectConversation).contact.id;
            selectedContact = contacts.cast<Contact?>().firstWhere(
              (c) => c?.id == id,
              orElse: () => null,
            );
          } else if (selectedConversation is GroupConversation) {
            final id = (selectedConversation as GroupConversation).group.id;
            final g = groups.cast<Group?>().firstWhere(
              (gr) => gr?.id == id,
              orElse: () => null,
            );
            if (g == null) {
              selectedConversation = null;
            } else {
              selectedConversation = GroupConversation(g);
            }
          }
        }
        isLoading = false;
      });
    } else if (isLoading) {
      setState(() => isLoading = false);
    }

    _syncActiveConversationTracker();
    unawaited(_consumePendingNotificationRoute());
    unawaited(_consumePendingCallAction());
  }

  bool _mapsEqual<K, V>(Map<K, V> a, Map<K, V> b) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (b[entry.key] != entry.value) return false;
    }
    return true;
  }

  bool _conversationPrefsEqual(
    Map<String, ConversationPreferences> a,
    Map<String, ConversationPreferences> b,
  ) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      final other = b[entry.key];
      if (other == null || other != entry.value) return false;
    }
    return true;
  }

  void saveAppUser(Contact user) async {
    await DBHelper.insertOrUpdateUser({
      'id': user.id,
      'name': user.name,
      'avatarUrl': user.avatarUrl,
      'avatarBase64': user.avatarBase64,
      'publicKeyPem': user.publicKeyPem,
    });
  }

  void _bootstrapDecoySession() {
    final data = DecoySessionData.build();
    appUser = data.appUser;
    contacts = data.contacts;
    groups = data.groups;
    conversations = data.conversations;
    _lastMessagePreviews = data.lastMessagePreviews;
    _unreadCounts = data.unreadCounts;
    _conversationPrefs = data.conversationPrefs;
    _decoyMessages = data.messagesByConversationId;
    isLoading = false;
  }

  void onUpdateProfile(Contact updatedUser) {
    setState(() {
      appUser = updatedUser;
    });
    if (widget.decoyMode) return;
    saveAppUser(updatedUser);
    // Persist avatar and username to SettingsService so /profile serves fresh data
    final settings = SettingsService();
    settings.setAvatar(updatedUser.avatarBase64);
    settings.setUsername(updatedUser.name);
    loadUsers();
  }

  void onSelectContact(Contact contact) {
    setState(() {
      selectedContact = contact;
      selectedConversation = DirectConversation(contact);
      showProfile = false;
      showSettings = false;
      showSelfChat = false;
    });
    _closeMobileDrawerIfOpen();
    _syncActiveConversationTracker();
    _dismissConversationNotification(senderId: contact.id);
  }

  void onSelectGroup(Group group) {
    setState(() {
      selectedContact = null;
      selectedConversation = GroupConversation(group);
      showProfile = false;
      showSettings = false;
      showSelfChat = false;
    });
    _closeMobileDrawerIfOpen();
    _syncActiveConversationTracker();
    _dismissConversationNotification(groupId: group.id, senderId: group.id);
  }

  void _showCreateGroup() {
    if (widget.decoyMode) {
      showPrysmToast(context, 
            'Could not create group. Make sure all members are online and try again.',
          );
      return;
    }
    Navigator.of(context).push(
      PrysmPageRoute(page: CreateGroupScreen(
          userId: widget.onionAddress,
          contacts: contacts,
          keyManager: widget.keyManager,
          onGroupCreated: (group) {
            loadUsers();
            onSelectGroup(group);
          },
        ),
      ),
    );
  }

  void onSelectSelfChat() {
    setState(() {
      showSelfChat = true;
      selectedContact = null;
      selectedConversation = SelfConversation(_selfChatLastTimestamp);
      showProfile = false;
      showSettings = false;
    });
    _closeMobileDrawerIfOpen();
  }

  void onShowProfile() {
    setState(() {
      showSettings = false;
      showProfile = true;
      showSelfChat = false;
    });
  }

  void onShowSettings() {
    setState(() {
      showSettings = true;
      showProfile = false;
      showSelfChat = false;
    });
  }

  void onThemeChanged(int themeIndex) {
    setState(() {
      currentTheme = themeIndex;
    });
    widget.onThemeChanged?.call(themeIndex);
  }

  void onAppearanceChanged() {
    widget.onAppearanceChanged?.call();
  }

  bool _isEditableFocused() {
    final ctx = FocusManager.instance.primaryFocus?.context;
    return ctx?.widget is EditableText;
  }

  Map<ShortcutActivator, VoidCallback> _desktopShortcut(
    LogicalKeyboardKey key,
    VoidCallback action,
  ) {
    if (!isDesktopPlatform) return {};
    void invoke() {
      if (_isEditableFocused()) return;
      action();
    }

    return {
      SingleActivator(key, control: true): invoke,
      if (Platform.isMacOS) SingleActivator(key, meta: true): invoke,
    };
  }

  String _desktopShortcutTooltip(String label, String key) {
    if (!isDesktopPlatform) return label;
    final mod = Platform.isMacOS ? 'Cmd' : 'Ctrl';
    return '$label ($mod+$key)';
  }

  Widget _tooltipIconButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback? onPressed,
  }) {
    return Semantics(
      label: tooltip,
      button: true,
      child: PrysmIconButton(
        icon: icon,
        onPressed: onPressed,
      ),
    );
  }

  Future<void> _showAddUserDialog({String? prefilledId}) async {
    if (widget.offlineMode) {
      showPrysmToast(context, 'Connect to Tor before adding contacts');
      return;
    }

    final hostContext = context;

    await showAddContactDialog(
      context: hostContext,
      prefilledId: prefilledId,
      decoyMode: widget.decoyMode,
      onAdd: (onionId, displayName, {expectedFingerprint}) async {
        final added = await _addNewUser(
          onionId,
          displayName,
          expectedFingerprint: expectedFingerprint,
        );
        if (added) unawaited(loadUsers());
        return added;
      },
      onScanQr: () async {
        Navigator.of(hostContext).pop();
        final scannedValue = await Navigator.push<String>(
          hostContext,
          PrysmPageRoute(page: const QrScannerScreen()),
        );
        if (scannedValue != null && scannedValue.isNotEmpty) {
          _showAddUserDialog(prefilledId: scannedValue);
        }
      },
    );
  }

  Future<bool> _addNewUser(
    String id,
    String name, {
    String? expectedFingerprint,
  }) async {
    return ContactAddService.instance.addContact(
      onionId: id,
      displayName: name,
      expectedFingerprint: expectedFingerprint,
    );
  }

  bool get _showSelfChatInSidebar {
    if (widget.decoyMode || _viewingArchived || _viewingBlocked) return false;
    if (_searchQuery.isEmpty) return true;
    return 'chat with myself'.contains(_searchQuery);
  }

  Widget _buildSelfChatSidebarTile() {
    final timeLabel = formatLastMessageTime(_selfChatLastTimestamp);
    final preview = _selfChatLastPreview;
    final subtitle = preview != null ? '$preview · $timeLabel' : timeLabel;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: GestureDetector(
        onSecondaryTapDown: isDesktopPlatform
            ? (details) => showConversationContextMenu(
                context: context,
                position: details.globalPosition,
                conversation: SelfConversation(_selfChatLastTimestamp),
                preferences: null,
                viewingArchived: false,
                canOpenDetached: _canOpenDetachedChat,
                showPinArchive: false,
                onOpenDetached: _openDetachedSelfChat,
              )
            : null,
        child: PrysmListRow(
          selected: showSelfChat,
          leading: ContactAvatar(
            name: appUser.name,
            avatarBase64: appUser.avatarBase64,
          ),
          title: 'Chat with myself',
          subtitle: subtitle,
          onTap: onSelectSelfChat,
        ),
      ),
    );
  }

  String formatLastMessageTime(int? timestamp) {
    if (timestamp == null) return "No message";
    final dt = DateTime.fromMillisecondsSinceEpoch(timestamp).toUtc().toLocal();
    final now = DateTime.now().toUtc();

    bool isSameDay =
        dt.year == now.year && dt.month == now.month && dt.day == now.day;

    if (isSameDay) {
      final h = dt.hour.toString().padLeft(2, '0');
      final m = dt.minute.toString().padLeft(2, '0');
      return '$h:$m';
    } else {
      final d = dt.day.toString().padLeft(2, '0');
      final mo = dt.month.toString().padLeft(2, '0');
      final y = (dt.year % 100).toString().padLeft(2, '0');
      final h = dt.hour.toString().padLeft(2, '0');
      final min = dt.minute.toString().padLeft(2, '0');
      return '$d/$mo/$y - $h:$min';
    }
  }

  Widget buildSidebar() {
    final isMobile =
        MediaQuery.of(context).size.width < 600;
    final tokens = context.prysmTokens;
    final safePadding = MediaQuery.paddingOf(context);

    return Container(
      margin: EdgeInsets.only(
        top: isMobile ? safePadding.top : 0,
        bottom: isMobile ? safePadding.bottom : 0,
      ),
      width: 320,
      decoration: BoxDecoration(
        color: tokens.sidebar,
        border: Border(
          right: BorderSide(color: tokens.divider, width: 1),
        ),
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: context.prysmStyle.tokens.divider.withValues(alpha: 0.1),
                  width: 1,
                ),
              ),
            ),
            child: Row(
              children: [
                ContactAvatar(
                  name: appUser.name,
                  radius: 20,
                  avatarBase64: appUser.avatarBase64,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        appUser.name,
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _onionPreview(widget.onionAddress),
                        style: TextStyle(
                          fontSize: 12,
                          color: context.prysmStyle.tokens.textMuted,
                        ),
                      ),
                    ],
                  ),
                ),
                _tooltipIconButton(
                  icon: PrysmIcons.qrCode,
                  tooltip: 'Show my QR code',
                  onPressed: () {
                    String? fingerprint;
                    try {
                      final parsed =
                          jsonDecode(widget.keyManager.publicKeyJson)
                              as Map<String, dynamic>;
                      fingerprint = parsed['fingerprint'] as String?;
                    } catch (_) {}
                    showPrysmIdQrDialog(
                      context,
                      encodeOnionToBase58(appUser.id),
                      fingerprint: fingerprint,
                    );
                  },
                ),
                if (QrPlatform.isScanSupported)
                  _tooltipIconButton(
                    icon: PrysmIcons.qrCodeScanner,
                    tooltip: 'Scan a QR code',
                    onPressed: () async {
                      final scanned = await Navigator.push<String>(
                        context,
                        PrysmPageRoute(page: const QrScannerScreen()),
                      );
                      if (scanned != null && scanned.isNotEmpty) {
                        _showAddUserDialog(prefilledId: scanned);
                      }
                    },
                  ),
              ],
            ),
          ),
          if (_viewingArchived)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                children: [
                  _tooltipIconButton(
                    icon: PrysmIcons.arrowBack,
                    tooltip: 'Back to chats',
                    onPressed: () => setState(() {
                      _viewingArchived = false;
                      _searchQuery = '';
                      _searchController.clear();
                    }),
                  ),
                  const Expanded(
                    child: Text(
                      'Archived',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 16,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          if (_viewingBlocked)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                children: [
                  _tooltipIconButton(
                    icon: PrysmIcons.arrowBack,
                    tooltip: 'Back to chats',
                    onPressed: () => setState(() {
                      _viewingBlocked = false;
                      _searchQuery = '';
                      _searchController.clear();
                    }),
                  ),
                  const Expanded(
                    child: Text(
                      'Blocked',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 16,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 8),
          // Search bar
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: PrysmSearchField(
              controller: _searchController,
              hintText: _viewingArchived
                  ? 'Search archived...'
                  : _viewingBlocked
                      ? 'Search blocked...'
                      : 'Search chats...',
              onChanged: (value) {
                setState(() => _searchQuery = value.trim().toLowerCase());
              },
              onClear: () {
                setState(() {
                  _searchQuery = '';
                  _searchController.clear();
                });
              },
            ),
          ),
          const SizedBox(height: 8),
          if (_showSelfChatInSidebar) _buildSelfChatSidebarTile(),
          // Conversation list
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: _filteredConversations.length + _sidebarFooterCount,
              itemBuilder: (_, index) {
                if (index >= _filteredConversations.length) {
                  final footerIndex = index - _filteredConversations.length;
                  final showArchivedFooter = _archivedCount > 0;
                  if (showArchivedFooter && footerIndex == 0) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      child: PrysmListRow(
                        leading: Icon(
                          PrysmIcons.archive,
                          color: context.prysmStyle.tokens.accent,
                        ),
                        title: 'Archived',
                        subtitle: '$_archivedCount',
                        trailing: _archivedUnreadCount > 0
                            ? Container(
                                width: 8,
                                height: 8,
                                decoration: BoxDecoration(
                                  color: context.prysmStyle.tokens.accent,
                                  shape: BoxShape.circle,
                                ),
                              )
                            : null,
                        onTap: () => setState(() {
                          _viewingArchived = true;
                          _viewingBlocked = false;
                        }),
                      ),
                    );
                  }
                  return Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    child: PrysmListRow(
                      leading: Icon(
                        PrysmIcons.blockOutlined,
                        color: context.prysmStyle.tokens.accent,
                      ),
                      title: 'Blocked',
                      subtitle:
                          '$_blockedCount contact${_blockedCount == 1 ? '' : 's'}',
                      onTap: () => setState(() {
                        _viewingBlocked = true;
                        _viewingArchived = false;
                      }),
                    ),
                  );
                }

                final conv = _filteredConversations[index];
                final isSelected = selectedConversation?.id == conv.id;
                final prefs = _conversationPrefs[conv.id];
                final isPinned = prefs?.isPinned ?? false;
                final Widget leading;
                final String subtitle;

                final unreadCount = _unreadCounts[conv.id] ?? 0;
                final preview = _lastMessagePreviews[conv.id];
                final timeLabel = formatLastMessageTime(
                  conv.lastMessageTimestamp,
                );

                if (conv is DirectConversation) {
                  final contact = conv.contact;
                  final isBlockedContact = BlockService.instance.isBlocked(
                    conv.id,
                  );
                  leading = ContactAvatar(
                    name: contact.displayName,
                    avatarBase64: contact.avatarBase64,
                  );
                  if (isBlockedContact) {
                    subtitle = timeLabel;
                  } else {
                    subtitle = preview != null
                        ? '$preview · $timeLabel'
                        : timeLabel;
                  }
                } else {
                  final group = (conv as GroupConversation).group;
                  leading = ContactAvatar(
                    name: group.name,
                    avatarBase64: group.avatarBase64,
                  );
                  subtitle = preview != null
                      ? 'Group · $preview · $timeLabel'
                      : 'Group · $timeLabel';
                }

                final isBlockedContact =
                    conv is DirectConversation &&
                    BlockService.instance.isBlocked(conv.id);

                return GestureDetector(
                  key: ValueKey(
                    '${conv.id}_${conv.lastMessageTimestamp ?? 0}_$unreadCount',
                  ),
                  onSecondaryTapDown: isDesktopPlatform
                      ? (details) => _showConversationContextMenu(
                          details.globalPosition,
                          conv,
                        )
                      : null,
                  onLongPress: () => _showConversationActions(conv),
                  child: PrysmListRow(
                    selected: isSelected,
                    onTap: () {
                      if (conv is DirectConversation) {
                        onSelectContact(conv.contact);
                      } else if (conv is GroupConversation) {
                        onSelectGroup(conv.group);
                      }
                    },
                    leading: SizedBox(
                      width: 48,
                      height: 48,
                      child: leading,
                    ),
                    title: conv.displayName,
                    subtitle: subtitle,
                    trailingSubtitle: timeLabel.contains(' · ')
                        ? timeLabel.split(' · ').last
                        : timeLabel,
                    trailing: unreadCount > 0 && !isBlockedContact
                        ? PrysmUnreadBadge(count: unreadCount)
                        : isBlockedContact && _viewingBlocked
                            ? Icon(PrysmIcons.block,
                                size: 18, color: tokens.textMuted)
                            : isPinned &&
                                    !_viewingArchived &&
                                    !_viewingBlocked
                                ? Icon(PrysmIcons.pushPin,
                                    size: 16, color: tokens.textMuted)
                                : null,
                  ),
                );
              },
            ),
          ),
          // Bottom buttons
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              border: Border(
                top: BorderSide(
                  color: context.prysmStyle.tokens.divider.withValues(alpha: 0.1),
                  width: 1,
                ),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _tooltipIconButton(
                  icon: PrysmIcons.settingsOutlined,
                  tooltip: _desktopShortcutTooltip('Settings', 'I'),
                  onPressed: onShowSettings,
                ),
                _tooltipIconButton(
                  icon: PrysmIcons.personOutline,
                  tooltip: 'Profile',
                  onPressed: onShowProfile,
                ),
                _tooltipIconButton(
                  icon: PrysmIcons.groupAddOutlined,
                  tooltip: _desktopShortcutTooltip('Create Group', 'G'),
                  onPressed: _showCreateGroup,
                ),
                _tooltipIconButton(
                  icon: PrysmIcons.addCircle,
                  tooltip: _desktopShortcutTooltip('Add Contact', 'N'),
                  onPressed: _showAddUserDialog,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _loadUsersDebounce?.cancel();
    _batterySaverSub?.cancel();
    _inboundRefreshSub?.cancel();
    _groupMembershipSub?.cancel();
    _torHealthTimer?.cancel();
    _torSupervisor?.dispose();
    _syncCoordinator?.dispose();
    if (NotificationService.onNotificationTap == _handleNotificationTap) {
      NotificationService.onNotificationTap = null;
    }
    if (NotificationService.onCallNotificationTap ==
        _handleCallNotificationAction) {
      NotificationService.onCallNotificationTap = null;
    }
    WidgetsBinding.instance.removeObserver(this);
    _searchController.dispose();
    _shutdownTor();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Never stop Tor on `inactive` — that fires on focus loss, dialogs, and
    // notifications, which was causing random shutdowns during normal use.
    // Desktop exit is handled by MyWindowListener; mobile uses `detached`.
    if (state == AppLifecycleState.resumed) {
      _syncActiveConversationTracker();
      unawaited(_consumePendingCallAction());
    } else {
      ActiveConversationTracker.instance.clear();
    }
    unawaited(CallForegroundSession.instance.onAppLifecycleChanged(state));
    if (state == AppLifecycleState.detached) {
      _shutdownTor();
    }
  }

  bool _torStopped = false;
  bool _torRestartInProgress = false;
  bool _torNeedsAttention = false;
  TorConnectionState _torConnectionState = TorConnectionState.connected;
  Timer? _torHealthTimer;
  DateTime? _lastTorDisconnectedAt;

  void _startTorHealthMonitor() {
    _torHealthTimer?.cancel();
    if (TorBootstrapNotifier.instance.progress >= 100) {
      _torConnectionState = TorConnectionState.connected;
      TorConnectionNotifier.instance.update(TorConnectionState.connected);
    }
    _torHealthTimer = Timer.periodic(BatterySaverPolicy.torHealthInterval(), (
      _,
    ) {
      _checkTorHealth();
    });
    _checkTorHealth();
  }

  Future<void> _checkTorHealth() async {
    if (!mounted || _torStopped || _torRestartInProgress) {
      if (mounted && _torConnectionState != TorConnectionState.disconnected) {
        _lastTorDisconnectedAt = DateTime.now();
        setState(() {
          _torConnectionState = TorConnectionState.disconnected;
          _torNeedsAttention = false;
        });
        TorConnectionNotifier.instance.update(TorConnectionState.disconnected);
      }
      return;
    }

    TorConnectionState next;
    var needsAttention = false;

    final supervisor = _torSupervisor;
    if (supervisor != null) {
      final evaluation = await supervisor.evaluateHealth();
      needsAttention =
          evaluation.connection == TorConnectionEvaluation.needsAttention;
      next = evaluation.connection == TorConnectionEvaluation.connected
          ? TorConnectionState.connected
          : TorConnectionState.disconnected;
    } else {
      final healthy = await widget.torManager.isHealthy();
      next = healthy
          ? TorConnectionState.connected
          : TorConnectionState.disconnected;
    }

    if (!mounted ||
        _torStopped ||
        _torRestartInProgress ||
        TorLifecycleNotifier.instance.blocked) {
      return;
    }

    final stateChanged = next != _torConnectionState;
    final attentionChanged = needsAttention != _torNeedsAttention;
    if (stateChanged || attentionChanged) {
      final wasDisconnected =
          _torConnectionState == TorConnectionState.disconnected;
      if (next == TorConnectionState.disconnected) {
        _lastTorDisconnectedAt = DateTime.now();
      }
      setState(() {
        _torConnectionState = next;
        _torNeedsAttention = needsAttention;
      });
      if (stateChanged) {
        TorConnectionNotifier.instance.update(next);
        if (wasDisconnected && next == TorConnectionState.connected) {
          unawaited(_onTorReconnected());
        }
      }
    }
  }

  Future<void> _maybeBroadcastWakeHints({bool coldStart = false}) async {
    if (_torStopped || widget.decoyMode) return;
    if (!coldStart) {
      final disconnectedAt = _lastTorDisconnectedAt;
      if (disconnectedAt == null) return;
      final offlineFor = DateTime.now().difference(disconnectedAt);
      if (offlineFor < BatterySaverPolicy.wakeHintMinOfflineBeforeBroadcast) {
        return;
      }
    }
    await WakeHintService.instance.broadcastRecentPeerHints();
  }

  Future<void> _onTorReconnected() async {
    if (!widget.decoyMode && TransportProvider.isConfigured) {
      TransportProvider.instance.wsManager.prepareForTorReconnect();
    }
    final flushed = await _syncCoordinator?.onTorReconnected() ?? false;
    if (mounted) {
      scheduleLoadUsers(light: true);
      if (flushed) {
        _syncCoordinator?.notifyPendingActivity();
      }
      unawaited(_maybeBroadcastWakeHints());
    }
  }

  Future<void> _restartTor() async {
    if (!mounted || _torRestartInProgress) return;
    final supervisor = _torSupervisor;
    if (supervisor != null) {
      await supervisor.restartTor(userInitiated: true);
    } else {
      await _performTorRestart(userInitiated: true);
    }
  }

  Future<void> _performTorRestart({bool userInitiated = false}) async {
    if (!mounted || _torRestartInProgress) return;

    _torRestartInProgress = true;
    _torHealthTimer?.cancel();
    _torStopped = true;
    TorLifecycleNotifier.instance.update(TorLifecycleState.restarting);

    if (!widget.decoyMode && TransportProvider.isConfigured) {
      TransportProvider.instance.wsManager.prepareForTorReconnect();
    }

    setState(() {
      _torConnectionState = TorConnectionState.connecting;
      _torNeedsAttention = false;
    });
    TorConnectionNotifier.instance.update(TorConnectionState.connecting);

    try {
      await widget.torManager.stopTor();
      if (!Platform.isAndroid && !Platform.isIOS) {
        await Future.delayed(TorManager.restartSettleDelay);
      }
      TorBootstrapNotifier.instance.reset();
      TorLifecycleNotifier.instance.update(TorLifecycleState.bootstrapping);
      await widget.torManager.startTor();
      _torStopped = false;
      TorLifecycleNotifier.instance.update(TorLifecycleState.ready);
      final onion = await widget.torManager.getOnionAddress();
      if (onion != null && onion.isNotEmpty) {
        PrysmServer.instance?.localOnionAddress = onion;
      }
      if (!mounted) return;
      setState(() {
        _torConnectionState = TorConnectionState.connected;
        _torNeedsAttention = false;
      });
      TorConnectionNotifier.instance.update(TorConnectionState.connected);
      await _onTorReconnected();
      if (userInitiated && mounted) {
        showPrysmToast(context, 'Tor restarted successfully');
      }
    } catch (e) {
      _torStopped = true;
      TorLifecycleNotifier.instance.update(TorLifecycleState.stopped);
      if (!mounted) return;
      setState(() {
        _torConnectionState = TorConnectionState.disconnected;
        _torNeedsAttention = false;
      });
      TorConnectionNotifier.instance.update(TorConnectionState.disconnected);
      if (userInitiated) {
        showPrysmToast(context, 'Tor restart failed: $e');
      }
    } finally {
      _torRestartInProgress = false;
      if (mounted && !_torStopped) {
        _startTorHealthMonitor();
      }
    }
  }

  void _showTorStatusSheet() {
    showPrysmSheet<void>(
      context: context,
      builder: (ctx) {
        final style = ctx.prysmStyle;
        final tokens = style.tokens;
        return Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Tor connection', style: style.headlineStyle),
              const SizedBox(height: 12),
              Row(
                children: [
                  _torStatusDot(_torConnectionState),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _torStatusLabel(_torConnectionState),
                      style: style.bodyStyle,
                    ),
                  ),
                ],
              ),
              if (_torNeedsAttention) ...[
                const SizedBox(height: 8),
                Text(
                  'Tor needs attention — automatic recovery paused. '
                  'Try Restart Tor manually.',
                  style: style.bodyStyle.copyWith(color: tokens.danger),
                ),
              ],
              if (_torSupervisor?.lastHealthFailureReason != null) ...[
                const SizedBox(height: 8),
                Text(
                  'Last issue: ${_torSupervisor!.lastHealthFailureReason}',
                  style: style.captionStyle,
                ),
              ],
              if (_torSupervisor != null &&
                  _torSupervisor!.autoRestartCount > 0) ...[
                const SizedBox(height: 4),
                Text(
                  'Auto-restarts: ${_torSupervisor!.autoRestartCount}',
                  style: style.captionStyle,
                ),
              ],
              if (TransportProvider.isConfigured) ...[
                const SizedBox(height: 8),
                Text(
                  'Outbound queue depth: '
                  '${TransportProvider.instance.outboundQueueDepth}',
                  style: style.captionStyle,
                ),
              ],
              if (!Platform.isAndroid && !Platform.isIOS) ...[
                const SizedBox(height: 4),
                Text(
                  'Health check: '
                  '${widget.torManager.lastHealthPollWasLight ? 'light (SOCKS)' : 'full (control)'}',
                  style: style.captionStyle,
                ),
              ],
              const SizedBox(height: 8),
              Text(
                'Onion: ${widget.onionAddress}',
                style: style.captionStyle,
              ),
              if (_torSupervisor != null &&
                  _torSupervisor!.recentStderrLines.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text('Recent Tor log', style: style.titleStyle),
                const SizedBox(height: 4),
                Container(
                  width: double.infinity,
                  constraints: const BoxConstraints(maxHeight: 120),
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: tokens.surfaceElevated,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: SingleChildScrollView(
                    child: Text(
                      _torSupervisor!.recentStderrLines.join('\n'),
                      style: style.captionStyle.copyWith(
                        fontFamily: 'monospace',
                        fontSize: 11,
                      ),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 20),
              if (widget.offlineMode) ...[
                PrysmButton(
                  label: widget.torConnecting ? 'Connecting…' : 'Connect Tor',
                  onPressed: widget.torConnecting
                      ? null
                      : () {
                          Navigator.pop(ctx);
                          widget.onConnectTor();
                        },
                ),
              ] else ...[
                PrysmButton(
                  label: 'Restart Tor',
                  onPressed:
                      _torConnectionState == TorConnectionState.connecting ||
                          _torRestartInProgress
                      ? null
                      : () {
                          Navigator.pop(ctx);
                          _restartTor();
                        },
                ),
                const SizedBox(height: 8),
                PrysmButton(
                  label: 'New circuit',
                  variant: PrysmButtonVariant.secondary,
                  onPressed: _torRestartInProgress
                      ? null
                      : () async {
                          Navigator.pop(ctx);
                          final ok = await widget.torManager.refreshCircuit();
                          if (!mounted) return;
                          showPrysmToast(
                            context,
                            ok
                                ? 'New Tor circuit requested'
                                : 'Circuit refresh failed',
                          );
                        },
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  String _onionPreview(String onion) {
    if (onion.isEmpty) return 'Connect Tor for Prysm ID';
    final short = onion.replaceAll('.onion', '');
    if (short.length <= 10) return short;
    return '${short.substring(0, 8)}…';
  }

  Widget _buildOfflineBanner() {
    if (!widget.offlineMode) return const SizedBox.shrink();
    final tokens = context.prysmStyle.tokens;
    return ColoredBox(
      color: tokens.danger.withValues(alpha: 0.15),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            Icon(
              PrysmIcons.wifiOff,
              size: 18,
              color: tokens.danger,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                widget.torConnecting
                    ? 'Connecting to Tor…'
                    : 'Offline — messages will send when Tor connects',
                style: TextStyle(
                  fontSize: 13,
                  color: tokens.danger,
                ),
              ),
            ),
            if (!widget.torConnecting)
              PrysmPressable(
                onTap: () => widget.onConnectTor(),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  child: Text(
                    'Connect',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: tokens.danger,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Color _torStatusColor(TorConnectionState state) => switch (state) {
    TorConnectionState.connected => const Color(0xFF4CAF50),
    TorConnectionState.connecting => const Color(0xFFFF9800),
    TorConnectionState.disconnected => const Color(0xFFF44336),
  };

  Widget _torStatusDot(TorConnectionState state, {double size = 10}) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: _torStatusColor(state),
        boxShadow: [
          BoxShadow(
            color: _torStatusColor(state).withValues(alpha: 0.45),
            blurRadius: 6,
            spreadRadius: 1,
          ),
        ],
      ),
    );
  }

  String _torStatusLabel(TorConnectionState state) {
    if (widget.torConnecting) return 'Connecting…';
    if (widget.offlineMode) return 'Offline';
    if (_torNeedsAttention) return 'Needs attention';
    return switch (state) {
      TorConnectionState.connected => 'Connected',
      TorConnectionState.connecting => 'Connecting…',
      TorConnectionState.disconnected => 'Disconnected',
    };
  }

  Widget _buildTorAppBarAction() {
    final color = _torStatusColor(_torConnectionState);
    final narrow = MediaQuery.sizeOf(context).width < 400;
    final shortLabel = switch (_torConnectionState) {
      TorConnectionState.connected => 'Tor',
      TorConnectionState.connecting => '…',
      TorConnectionState.disconnected => widget.offlineMode ? 'Off' : 'Off',
    };

    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: Semantics(
        label: 'Tor: ${_torStatusLabel(_torConnectionState)}',
        button: true,
        child: PrysmPressable(
          onTap: _showTorStatusSheet,
          borderRadius: BorderRadius.circular(20),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: narrow ? 10 : 12,
                vertical: 8,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(PrysmIcons.shieldOutlined, size: 18, color: color),
                  const SizedBox(width: 6),
                  _torStatusDot(_torConnectionState, size: 8),
                  if (!narrow) ...[
                    const SizedBox(width: 6),
                    Text(
                      shortLabel,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: color,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _copyPrysmId() {
    final id = encodeOnionToBase58(appUser.id);
    Clipboard.setData(ClipboardData(text: id));
    showPrysmToast(context, 'Prysm ID copied to clipboard');
  }

  Widget _buildEmptyHomeState() {
    final prysmId = encodeOnionToBase58(appUser.id);
    final contactCount = contacts
        .where((c) => c.id != widget.onionAddress)
        .length;
    final groupCount = groups.length;
    final displayName = appUser.name.isNotEmpty ? appUser.name : 'there';

    return EmptyHomeState(
      displayName: displayName,
      prysmId: prysmId,
      contactCount: contactCount,
      groupCount: groupCount,
      onCopyId: _copyPrysmId,
      onShowQr: () => showPrysmIdQrDialog(context, prysmId),
      onAddContact: _showAddUserDialog,
      onCreateGroup: _showCreateGroup,
      onScanQr: QrPlatform.isScanSupported
          ? () async {
              final scanned = await Navigator.push<String>(
                context,
                PrysmPageRoute(page: const QrScannerScreen()),
              );
              if (scanned != null && scanned.isNotEmpty) {
                _showAddUserDialog(prefilledId: scanned);
              }
            }
          : null,
    );
  }

  Future<void> _shutdownTor() async {
    if (!_torStopped) {
      _torStopped = true;
      TorLifecycleNotifier.instance.update(TorLifecycleState.stopped);
      _torHealthTimer?.cancel();
      await widget.torManager.stopTor();
      Logging.info('Tor process stopped gracefully.', 'Main');
    }
  }

  void clearChat() {
    setState(() {
      loadUsers();
      selectedContact = null;
      selectedConversation = null;
      showSelfChat = false;
    });
    _syncActiveConversationTracker();
  }

  Widget _buildChatBody() {
    if (showProfile) {
      return ProfileScreen(
        user: appUser,
        onClose: () => setState(() => showProfile = false),
        onUpdate: onUpdateProfile,
        reloadUsers: () => loadUsers(),
        onScanResult: (scanned) => _showAddUserDialog(prefilledId: scanned),
      );
    }
    if (showSettings) {
      return SettingsScreen(
        onClose: () => setState(() => showSettings = false),
        onThemeChanged: onThemeChanged,
        onAppearanceChanged: onAppearanceChanged,
        torManager: widget.torManager,
        keyManager: widget.decoyMode ? null : widget.keyManager,
        onionAddress: widget.decoyMode ? null : widget.onionAddress,
        offlineMode: widget.offlineMode,
        torConnecting: widget.torConnecting,
        onConnectTor: widget.onConnectTor,
      );
    }
    if (showSelfChat && !widget.decoyMode) {
      return SelfChatScreen(
        key: const ValueKey('self_chat'),
        userId: appUser.id,
        userName: appUser.name,
        avatarBase64: appUser.avatarBase64,
        keyManager: widget.keyManager,
        onCloseChat: () => clearChat(),
        reloadSidebar: () => loadUsers(),
      );
    }
    if (selectedConversation is GroupConversation) {
      final group = (selectedConversation as GroupConversation).group;
      if (widget.decoyMode) {
        return DecoyChatScreen(
          key: ValueKey('decoy_group_${group.id}'),
          conversationId: group.id,
          title: group.name,
          avatarName: group.name,
          avatarBase64: group.avatarBase64,
          isGroup: true,
          initialMessages: _decoyMessages[group.id] ?? const [],
          onCloseChat: () => clearChat(),
        );
      }
      return GroupChatScreen(
        key: ValueKey('group_${group.id}'),
        userId: appUser.id,
        group: group,
        contacts: contacts,
        keyManager: widget.keyManager,
        reloadConversations: () => loadUsers(),
        onCloseChat: () => clearChat(),
        torStatusAction: widget.decoyMode ? null : _buildTorAppBarAction(),
      );
    }
    if (selectedContact != null) {
      if (widget.decoyMode) {
        final contact = selectedContact!;
        return DecoyChatScreen(
          key: ValueKey('decoy_dm_${contact.id}'),
          conversationId: contact.id,
          title: contact.displayName,
          avatarName: contact.displayName,
          avatarBase64: contact.avatarBase64,
          initialMessages: _decoyMessages[contact.id] ?? const [],
          onCloseChat: () => clearChat(),
        );
      }
      return ChatScreen(
        userId: appUser.id,
        userName: appUser.name,
        peerId: selectedContact!.id,
        peerName: selectedContact!.displayName,
        peerAvatarBase64: selectedContact!.avatarBase64,
        peerPublicKeyPem: selectedContact!.publicKeyPem,
        torManager: widget.torManager,
        keyManager: widget.keyManager,
        currentTheme: currentTheme,
        clearChat: () => clearChat(),
        reloadUsers: () => loadUsers(),
        onCloseChat: () => clearChat(),
        torStatusAction: widget.decoyMode ? null : _buildTorAppBarAction(),
      );
    }
    return _buildEmptyHomeState();
  }

  Widget _buildHomeHeader({
    required bool showMenuButton,
    required List<Widget> actions,
  }) {
    final tokens = context.prysmStyle.tokens;
    return ColoredBox(
      color: tokens.surface,
      child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: 70,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  children: [
                    if (showMenuButton)
                      _tooltipIconButton(
                        icon: PrysmIcons.menu,
                        tooltip: 'Open menu',
                        onPressed: () => setState(() => _sidebarOpen = true),
                      ),
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: tokens.accent.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Image.asset(
                        'assets/logo.png',
                        height: 40,
                        width: 40,
                        fit: BoxFit.contain,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        '${settings.name} Chat',
                        style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    ...actions,
                  ],
                ),
              ),
            ),
            Container(height: 1, color: tokens.divider),
          ],
        ),
    );
  }

  Widget _buildHomeBody({required bool isMobile}) {
    final tokens = context.prysmStyle.tokens;
    final showHomeHeader = isMobile &&
        selectedConversation == null &&
        !showProfile &&
        !showSettings &&
        !showSelfChat;

    final content = ColoredBox(
      color: tokens.background,
      child: Column(
        children: [
          if (isMobile)
            SizedBox(height: MediaQuery.paddingOf(context).top),
          if (showHomeHeader)
            _buildHomeHeader(
              showMenuButton: true,
              actions: [
                if (!widget.decoyMode) _buildTorAppBarAction(),
                _tooltipIconButton(
                  icon: PrysmIcons.settingsOutlined,
                  tooltip: 'Settings',
                  onPressed: () => setState(() {
                    showSettings = true;
                    showSelfChat = false;
                  }),
                ),
              ],
            )
          else if (!isMobile)
            _buildHomeHeader(
              showMenuButton: false,
              actions: [
                if (!widget.decoyMode) _buildTorAppBarAction(),
                _tooltipIconButton(
                  icon: PrysmIcons.settingsOutlined,
                  tooltip: _desktopShortcutTooltip('Settings', 'I'),
                  onPressed: onShowSettings,
                ),
              ],
            ),
          _buildOfflineBanner(),
          Expanded(
            child: isMobile
                ? MediaQuery.removePadding(
                    context: context,
                    removeTop: true,
                    child: _buildChatBody(),
                  )
                : Row(
                    children: [
                      buildSidebar(),
                      Expanded(child: _buildChatBody()),
                    ],
                  ),
          ),
        ],
      ),
    );

    if (!isMobile || !_sidebarOpen) {
      return content;
    }

    return Stack(
      children: [
        content,
        Positioned.fill(
          child: GestureDetector(
            onTap: () => setState(() => _sidebarOpen = false),
            child: const ColoredBox(color: Color(0x66000000)),
          ),
        ),
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          child: buildSidebar(),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final isMobile = MediaQuery.of(context).size.width < 600;

    if (isLoading) {
      return const PrysmPage(body: Center(child: PrysmProgressIndicator()));
    }

    if (isMobile) {
      return _buildHomeBody(isMobile: true);
    }

    return CallbackShortcuts(
      bindings: {
        ..._desktopShortcut(LogicalKeyboardKey.keyN, _showAddUserDialog),
        ..._desktopShortcut(LogicalKeyboardKey.keyI, onShowSettings),
        ..._desktopShortcut(LogicalKeyboardKey.keyG, _showCreateGroup),
      },
      child: Focus(
        autofocus: true,
        child: _buildHomeBody(isMobile: false),
      ),
    );
  }
}
