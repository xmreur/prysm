import 'package:flutter/widgets.dart';
import 'package:prysm/l10n/l10n_extensions.dart';
import 'package:prysm/ui/core/prysm_icons.dart';
import 'package:prysm/ui/core/prysm_progress.dart';
import 'package:prysm/theme/prysm_style_scope.dart';
import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:prysm/app/bootstrap.dart';
import 'package:prysm/app/app_composition.dart';
import 'package:prysm/app/tor_connection_controller.dart';
import 'package:prysm/app/unlock_controller.dart';
import 'package:prysm/models/unlock_type.dart';
import 'package:prysm/screens/unlock_screen.dart';
import 'package:prysm/screens/crypto_migration_screen.dart';
import 'package:prysm/screens/startup_fatal_error_screen.dart';
import 'package:prysm/screens/home/home_screen.dart';
import 'package:prysm/crypto/key_store.dart';
import 'package:prysm/server/PrysmServer.dart';
import 'package:prysm/services/battery_saver_service.dart';
import 'package:prysm/services/block_service.dart';
import 'package:prysm/services/notification_mute_service.dart';
import 'package:prysm/services/settings_service.dart';
import 'package:prysm/services/tray_service.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/logging.dart';
import 'package:prysm/screens/call/call_overlay.dart';
import 'package:prysm/services/call/call_foreground_session.dart';
import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:prysm/models/detached_chat_launch.dart';
import 'package:prysm/screens/detached_chat_app.dart';
import 'package:prysm/services/detached_chat_host.dart';
import 'package:prysm/services/detached_chat_window_registry.dart';
import 'package:prysm/util/app_bootstrap.dart';
import 'package:prysm/util/desktop_platform.dart';
import 'package:prysm/util/sqflite_platform.dart';
import 'package:prysm/util/tor_service.dart'; // Updated Tor service
import 'package:prysm/transport/peer_transport_registry.dart';
import 'package:prysm/ui/prysm_list_row.dart';
import 'package:prysm/ui/core/prysm_app.dart';
import 'package:prysm/ui/core/prysm_button.dart';
import 'package:prysm/util/notification_service.dart';
import 'package:prysm/util/schedule_time_format.dart';
import 'package:prysm/services/share_intent_service.dart';
import 'package:prysm/util/decoy_session_data.dart';
import 'package:prysm/screens/onboarding/onboarding_screen.dart';
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

/// Stops Android background work and removes the app from recents before OTA install.
Future<void> shutdownForAndroidUpdate() async {
  if (!Platform.isAndroid) {
    exit(0);
  }

  try {
    await FlutterBackground.disableBackgroundExecution();
  } catch (_) {}

  final torManager = _globalTorManager;
  if (torManager != null) {
    try {
      await torManager.stopTor();
    } catch (_) {}
  }

  try {
    const channel = MethodChannel('prysm/app_lifecycle');
    await channel.invokeMethod<void>('finishForUpdate');
  } catch (_) {}

  exit(0);
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
  await ensureScheduleDateFormatting();
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

    final guard = SingleInstanceGuard(
      fileExists: (path) => File(path).exists(),
      readFile: (path) => File(path).readAsString(),
      checkProcessRunning: isProcessRunning,
      writeFile: (path, pidStr) async {
        await File(path).writeAsString(pidStr);
      },
    );
    final runningPid = await guard.detectRunningInstance(
      lockFilePath: _lockFile!.path,
      currentPid: '$pid',
    );
    if (runningPid != null) {
      // Another instance is running — activate it and exit
      Logging.info('Another instance of Prysm is already running (PID $runningPid).', 'Main');
      exit(0);
    }

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

  final keyManager = KeyManager();

  // Start early so Tor peers can connect during bootstrap / unlock screen.
  final messageServer = PrysmServer(port: 12345, keyManager: keyManager);

  final bootstrapResult = await AppBootstrap.initializeServices(
    keyManager: keyManager,
    initSettings: () => SettingsService().init(),
    initPeerTransportRegistry: () => PeerTransportRegistry.instance.load(),
    initBatterySaver: () => BatterySaverService.instance.init(),
    initNotificationMute: () => NotificationMuteService.instance.init(),
    initBlockService: () => BlockService.instance.init(),
    startServer: () => messageServer.start(),
  );
  AppComposition.configureLocalOnionAddressProvider();

  runApp(
    MyApp(
      keyManager: bootstrapResult.keyManager,
      startupError: bootstrapResult.startupError,
      serverBindFailed: bootstrapResult.serverBindFailed,
    ),
  );

  if (!Platform.isAndroid && !Platform.isIOS) {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await AppBootstrap.showDesktopWindow(
        ensureInitialized: windowManager.ensureInitialized,
        setTitleBarStyle: () =>
            windowManager.setTitleBarStyle(TitleBarStyle.normal),
        show: windowManager.show,
        focus: windowManager.focus,
        initTray: TrayService.instance.init,
      );
    });
  }

  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(NotificationService().init());
    if (Platform.isAndroid) {
      unawaited(ShareIntentService.instance.init());
    }
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

  late final UnlockController _unlockController = UnlockController(
    keyManager: widget.keyManager,
    settings: settings,
  );

  late final TorConnectionController torConnectionController =
      TorConnectionController(
    keyManager: widget.keyManager,
    onConnected: (result) {
      _globalTorManager = result.torManager;
      if (!Platform.isAndroid && !Platform.isIOS) {
        windowManager.addListener(MyWindowListener(result.torManager));
      }
    },
  );

  bool unlocked = false;
  bool _keysChecked = false;
  bool _keysExist = false;
  bool _needsMigration = false;
  bool _migrationChecked = false;
  String? _startupError;
  bool _panicDecoySession = false;
  int _currentTheme = 0;

  void _onTorControllerChanged() {
    if (mounted) setState(() {});
  }

  Future<bool> onVerifyUnlock(String secret) async {
    final result = await _unlockController.verifyUnlock(secret);
    if (result.unlocked && mounted) {
      setState(() {
        unlocked = true;
        _keysExist = true;
        _panicDecoySession = result.decoySession;
      });
    }
    return result.unlocked;
  }

  Future<bool> onVerifyPassphrase(String passphrase) =>
      onVerifyUnlock(passphrase);

  Future<bool> onVerifyPin(String pin) => onVerifyUnlock(pin);

  @override
  void initState() {
    super.initState();
    ShareIntentService.instance.isDecoyMode = () => _panicDecoySession;
    _startupError = widget.startupError;
    _loadSavedTheme();
    _checkMigration();
    _checkKeysExist();
    unawaited(Logging.init());
    torConnectionController.addListener(_onTorControllerChanged);
    settings.localeRevision.addListener(_onLocaleRevision);
    unawaited(torConnectionController.checkStartupConnectivity());
  }

  void _onLocaleRevision() {
    if (mounted) setState(() {});
    unawaited(ensureScheduleDateFormatting());
    unawaited(TrayService.instance.refreshMenu());
    unawaited(NotificationService().refreshLocalizedChannels());
  }

  @override
  void dispose() {
    settings.localeRevision.removeListener(_onLocaleRevision);
    torConnectionController.removeListener(_onTorControllerChanged);
    torConnectionController.dispose();
    super.dispose();
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
      key: ValueKey('prysm_app_root_${settings.localeRevision.value}'),
      themePalette: _currentTheme,
      appearance: settings.appearance,
      localeOverride: settings.localeOverride,
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
          onionAddress: torConnectionController.onionAddress ?? '',
          torReady: torConnectionController.ready,
          offlineMode: torConnectionController.offline,
          torBootstrapProgress: torConnectionController.bootstrapProgress > 0
              ? torConnectionController.bootstrapProgress
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
          torBootstrapProgress: torConnectionController.bootstrapProgress > 0
              ? torConnectionController.bootstrapProgress
              : null,
        ),
      );
    }
    if (!torConnectionController.ready && !torConnectionController.offline) {
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
                    if (torConnectionController.failed)
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
                        torConnectionController.status,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      torConnectionController.failed
                          ? 'You can use Prysm offline or retry when you have a connection.'
                          : torConnectionController.bootstrapProgress > 0
                          ? 'Tor bootstrap: ${torConnectionController.bootstrapProgress}%'
                          : 'Setting up secure connection...',
                      style: TextStyle(
                        fontSize: 13,
                        color: tokens.textMuted,
                      ),
                    ),
                    if (!torConnectionController.failed &&
                        torConnectionController.bootstrapProgress > 0) ...[
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
                                  (torConnectionController.bootstrapProgress /
                                          100)
                                      .clamp(0.0, 1.0),
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
                    if (torConnectionController.failed) ...[
                      const SizedBox(height: 24),
                      PrysmButton(
                        label: 'Retry',
                        onPressed: torConnectionController.retry,
                      ),
                      const SizedBox(height: 12),
                      PrysmButton(
                        label: context.l10n.continueOffline,
                        variant: PrysmButtonVariant.secondary,
                        onPressed: torConnectionController.enterOfflineMode,
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
        : (torConnectionController.onionAddress ?? '');
    final showOnboarding = !_panicDecoySession && !settings.onboardingCompleted;

    return _prysmApp(
      title: '${settings.name} Chat',
      home: showOnboarding
          ? OnboardingScreen(
              onionAddress: onionAddress,
              torReady: torConnectionController.ready,
              offlineMode: torConnectionController.offline,
              onComplete: () {
                if (mounted) setState(() {});
              },
            )
          : CallOverlay(
              decoyMode: _panicDecoySession,
              child: HomeScreen(
                torManager: torConnectionController.torManager!,
                torConnectionController: torConnectionController,
                onionAddress: onionAddress,
                keyManager: widget.keyManager,
                onThemeChanged: updateTheme,
                onAppearanceChanged: updateAppearance,
                currentTheme: _currentTheme,
                decoyMode: _panicDecoySession,
                offlineMode: torConnectionController.offline,
                torConnecting: torConnectionController.connecting,
                onConnectTor: torConnectionController.connect,
              ),
            ),
    );
  }
}

