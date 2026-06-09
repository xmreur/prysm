import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_chat_core/flutter_chat_core.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:prysm/database/messages.dart';
import 'package:prysm/models/panic_action.dart';
import 'package:prysm/screens/pin_entry.dart';
import 'package:prysm/services/panic_pin_service.dart';
import 'package:prysm/services/panic_wipe_service.dart';
import 'package:prysm/screens/settings_screen.dart';
import 'package:prysm/server/PrysmServer.dart';
import 'package:prysm/services/battery_saver_service.dart';
import 'package:prysm/services/notification_mute_service.dart';
import 'package:prysm/services/settings_service.dart';
import 'package:prysm/util/battery_saver_policy.dart';
import 'package:prysm/services/tray_service.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/updater_downloader.dart';
import 'package:prysm/screens/chat.dart';
import 'package:prysm/screens/create_group_screen.dart';
import 'package:prysm/screens/group_chat.dart';
import 'package:prysm/models/conversation.dart';
import 'package:prysm/models/conversation_preferences.dart';
import 'package:prysm/models/group.dart';
import 'package:prysm/services/conversation_preferences_service.dart';
import 'package:prysm/screens/widgets/conversation_actions_sheet.dart';
import 'package:prysm/services/group_service.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/util/tor_service.dart'; // Updated Tor service
import 'package:prysm/util/tor_downloader.dart';
import 'package:prysm/util/tor_outbound_gateway.dart';
import 'package:prysm/util/tor_runtime_gate.dart';
import 'package:prysm/util/tor_supervisor.dart';
import 'package:prysm/screens/profile_screen.dart';
import 'package:prysm/screens/widgets/contact_avatar.dart';
import 'package:prysm/models/contact.dart';
import 'package:prysm/util/theme_manager.dart';
import 'package:prysm/util/notification_service.dart';
import 'package:prysm/util/conversation_refresh_notifier.dart';
import 'package:prysm/util/group_membership_notifier.dart';
import 'package:prysm/util/tor_bootstrap_notifier.dart';
import 'package:prysm/screens/widgets/qr_scanner_screen.dart';
import 'package:prysm/screens/widgets/prysm_id_qr.dart';
import 'package:prysm/util/onion_id_codec.dart';
import 'package:prysm/util/decoy_session_data.dart';
import 'package:prysm/screens/decoy_chat_screen.dart';
import 'package:prysm/screens/onboarding/onboarding_screen.dart';
import 'package:prysm/services/contact_add_service.dart';
import 'package:prysm/util/qr_platform.dart';
import 'package:prysm/util/tor_connection_notifier.dart';
import 'package:prysm/services/sync_coordinator.dart';
import 'package:prysm/services/wake_hint_service.dart';
import 'package:flutter_background/flutter_background.dart';
import 'package:window_manager/window_manager.dart';

TorManager? _globalTorManager;
File? _lockFile;

Future<void> quitApp({TorManager? torManager}) async {
  if (!Platform.isAndroid && !Platform.isIOS) {
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

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

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
        print('Another instance of Prysm is already running (PID $pid).');
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
  await BatterySaverService.instance.init();
  await NotificationMuteService.instance.init();

  final keyManager = KeyManager();

  // Start the message server early so incoming messages are received
  // even while Tor is still bootstrapping or the user is on the PIN screen.
  final messageServer = PrysmServer(port: 12345, keyManager: keyManager);
  messageServer.start();

  runApp(MyApp(keyManager: keyManager));

  if (!Platform.isAndroid && !Platform.isIOS) {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await windowManager.ensureInitialized();
      await windowManager.show();
      await windowManager.focus();
      await TrayService.instance.init();
    });
  }

  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(NotificationService().init());
  });

  // Request Android permissions and start background service AFTER runApp
  // so the Flutter UI is rendered before any permission dialogs appear.
  if (Platform.isAndroid) {
    Future.microtask(() async {
      await NotificationService().requestPermission();
      final settings = SettingsService();
      final androidConfig = FlutterBackgroundAndroidConfig(
        notificationTitle: "${settings.name} Chat is running",
        notificationText: "${settings.name} chat is actively waiting for new messages",
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
    print('Error downloading updater: $e');
  }
}

Future<TorInitResult> initializeTor() async {
  TorBootstrapNotifier.instance.reset();
  var torPath = "";
  if (!Platform.isAndroid) {
    final torDownloader = TorDownloader();
    torPath = await torDownloader.getOrDownloadTor();
  }

  final documentsDir = await getApplicationDocumentsDirectory();
  final dataDirPath = p.join(documentsDir.path, 'prysm', 'tor_executable', 'tor_data');

  final dataDir = Directory(dataDirPath);
  if (!dataDir.existsSync()) {
    dataDir.createSync(recursive: true);
  }

  final torManager = TorManager(
    torPath: torPath,
    dataDir: dataDirPath,
    controlPassword: 'your_strong_password_here',
  );

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
  // Simple version comparison (assumes vX.Y.Z format)
  List<int> toNums(String v) =>
      v.replaceFirst('v', '').split('.').map(int.parse).toList();

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
  final url = Uri.parse('https://api.github.com/repos/xmreur/prysm/releases/latest');

  try {
    final response = await http.get(url);
    if (response.statusCode == 200) {
      final jsonData = jsonDecode(response.body);

      final latestVersion = jsonData['tag_name'] as String;

      if (await isNewerVersion(currentVersion, latestVersion)) {

        
        final updaterPath = await UpdaterDownloader().getOrDownloadUpdater();


        print('Launching updater process...');
        await Process.start(
          updaterPath,
          [],
          mode: ProcessStartMode.detached,
        );

        // Exit app to allow updater to proceed
        exit(0);
      } else {
        print('Already at latest version $currentVersion');
      }
    } else {
      print('Failed to fetch latest release info. Status: ${response.statusCode}');
    }
  } catch (e) {
    print('Error checking updates: $e');
  }
}

class MyWindowListener extends WindowListener {
  final TorManager torManager;
  MyWindowListener(this.torManager);

  @override
  void onWindowClose() async {
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

  const MyApp({
    required this.keyManager,
    super.key,
  });

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {

    static final settings = SettingsService();
    
  bool unlocked = false;
  bool _panicDecoySession = false;
  int _currentTheme = 0;

  // Tor init state
  TorManager? _torManager;
  String? _onionAddress;
  String _torStatus = 'Initializing...';
  bool _torReady = false;
  bool _torFailed = false;
  int _torBootstrapProgress = 0;
  StreamSubscription<int>? _bootstrapSub;

  @override
  void dispose() {
    _bootstrapSub?.cancel();
    super.dispose();
  }

  Future<bool> onVerifyPin(String pin) async {
    final keyManager = widget.keyManager;
    if (await keyManager.unlockWithPin(pin)) {
      await settings.migrateOnboardingIfExisting(
        readPublicKey: () => keyManager.safeRead('PUBLIC_KEY'),
        contactCount: (await DBHelper.getUsers()).length,
      );
      setState(() {
        unlocked = true;
        _panicDecoySession = false;
      });
      return true;
    }

    if (await PanicPinService.instance.isConfigured() &&
        await PanicPinService.instance.verify(pin)) {
      if (settings.panicAction == PanicAction.wipe) {
        await PanicWipeService.wipeAll();
        await keyManager.wipeSecureStorage();
        await settings.load();
      } else {
        keyManager.lock();
      }
      await keyManager.loadEphemeralKeys();
      setState(() {
        unlocked = true;
        _panicDecoySession = true;
      });
      return true;
    }

    return false;
  }

  @override
  void initState() {
    super.initState();
    _loadSavedTheme();
    _bootstrapSub = TorBootstrapNotifier.instance.onProgress.listen((p) {
      if (mounted) setState(() => _torBootstrapProgress = p);
    });
    _initTorInBackground();
  }

  Future<void> _initTorInBackground() async {
    try {
      setState(() => _torStatus = 'Starting Tor...');
      final result = await initializeTor();
      _globalTorManager = result.torManager;
      TorOutboundGateway.configure(result.torManager);

      if (!Platform.isAndroid) {
        windowManager.addListener(MyWindowListener(result.torManager));
      }

      if (mounted) {
        PrysmServer.instance?.localOnionAddress = result.onionAddress;
        setState(() {
          _torManager = result.torManager;
          _onionAddress = result.onionAddress;
          _torReady = true;
          _torFailed = false;
          _torStatus = 'Connected';
        });
      }
    } catch (e) {
      print('Tor initialization failed: $e');
      if (mounted) {
        setState(() {
          _torFailed = true;
          _torStatus = 'Failed to connect to Tor. Check your network and try again.';
        });
      }
    }
  }

  Future<void> _retryTor() async {
    setState(() {
      _torFailed = false;
      _torReady = false;
      _torStatus = 'Retrying Tor connection...';
    });
    await _initTorInBackground();
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

  @override
  Widget build(BuildContext context) {
    if (!unlocked) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        title: "Unlock ${settings.name} Chat",
        theme: ThemeManager.getTheme(_currentTheme),
        home: PinScreen(
          onVerifyPin: onVerifyPin,
          isPinSet: widget.keyManager.isPinSet(),
          torBootstrapProgress: _torBootstrapProgress > 0 ? _torBootstrapProgress : null,
        ),
      );
    }
    if (!_torReady) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        title: '${settings.name} Chat',
        theme: ThemeManager.getTheme(_currentTheme),
        home: Scaffold(
          body: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (_torFailed)
                  Icon(Icons.wifi_off, size: 48, color: Theme.of(context).colorScheme.error)
                else
                  const CircularProgressIndicator(),
                const SizedBox(height: 24),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: Text(
                    _torStatus,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  _torFailed
                      ? 'Tor is required for Prysm to work'
                      : _torBootstrapProgress > 0
                          ? 'Tor bootstrap: $_torBootstrapProgress%'
                          : 'Setting up secure connection...',
                  style: TextStyle(fontSize: 13, color: Theme.of(context).hintColor),
                ),
                if (!_torFailed && _torBootstrapProgress > 0) ...[
                  const SizedBox(height: 12),
                  SizedBox(
                    width: 200,
                    child: LinearProgressIndicator(value: _torBootstrapProgress / 100),
                  ),
                ],
                if (_torFailed) ...[
                  const SizedBox(height: 24),
                  ElevatedButton.icon(
                    onPressed: _retryTor,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Retry'),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    }
    final onionAddress = _panicDecoySession
        ? DecoySessionData.identityOnion
        : _onionAddress!;
    final showOnboarding =
        !_panicDecoySession && !settings.onboardingCompleted;

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: '${settings.name} Chat',
      theme: ThemeManager.getTheme(_currentTheme),
      home: showOnboarding
          ? OnboardingScreen(
              onionAddress: onionAddress,
              torReady: _torReady,
              onComplete: () {
                if (mounted) setState(() {});
              },
            )
          : HomeScreen(
              torManager: _torManager!,
              onionAddress: onionAddress,
              keyManager: widget.keyManager,
              onThemeChanged: updateTheme,
              currentTheme: _currentTheme,
              decoyMode: _panicDecoySession,
            ),
    );
  }
}

class HomeScreen extends StatefulWidget {
  final TorManager torManager;
  final String onionAddress;
  final KeyManager keyManager;
  final Function(int)? onThemeChanged;
  final int currentTheme;
  final bool decoyMode;

  const HomeScreen({
    required this.torManager,
    required this.onionAddress,
    required this.keyManager,
    this.onThemeChanged,
    this.currentTheme = 0,
    this.decoyMode = false,
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
  bool isLoading = true;
  int currentTheme = 0; // 0: Light, 1: Dark, 2: Pink, 3: Cyan, 4: Purple, 5 Orange
  String _searchQuery = '';
  Map<String, String> _lastMessagePreviews = {};
  Map<String, int> _unreadCounts = {};
  Map<String, ConversationPreferences> _conversationPrefs = {};
  Map<String, List<DecoyMessage>> _decoyMessages = {};
  bool _viewingArchived = false;

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

  int get _archivedCount =>
      conversations.where((c) => _conversationPrefs[c.id]?.isArchived ?? false).length;

  int get _archivedUnreadCount => conversations
      .where(
        (c) =>
            (_conversationPrefs[c.id]?.isArchived ?? false) &&
            (_unreadCounts[c.id] ?? 0) > 0,
      )
      .length;

  List<Conversation> get _filteredConversations {
    return conversations.where((c) {
      final archived = _conversationPrefs[c.id]?.isArchived ?? false;
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
      _conversationPrefs = Map.of(_conversationPrefs)..[pref.conversationId] = pref;
      ConversationPreferencesService.sortConversations(conversations, _conversationPrefs);
    });
  }

  Future<void> _pinConversation(String id) async {
    if (widget.decoyMode) {
      _updateDecoyConversationPref(ConversationPreferences(
        conversationId: id,
        isPinned: true,
        pinnedAt: DateTime.now().millisecondsSinceEpoch,
      ));
      return;
    }
    await ConversationPreferencesService.instance.pin(id);
    await _reloadConversationPreferences();
  }

  Future<void> _unpinConversation(String id) async {
    if (widget.decoyMode) {
      _updateDecoyConversationPref(ConversationPreferences(
        conversationId: id,
      ));
      return;
    }
    await ConversationPreferencesService.instance.unpin(id);
    await _reloadConversationPreferences();
  }

  Future<void> _archiveConversation(String id) async {
    if (widget.decoyMode) {
      _updateDecoyConversationPref(ConversationPreferences(
        conversationId: id,
        isArchived: true,
        archivedAt: DateTime.now().millisecondsSinceEpoch,
      ));
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
      _updateDecoyConversationPref(ConversationPreferences(
        conversationId: id,
      ));
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
        publicKeyPem: 'NONE',
      );
    }
    _syncCoordinator = SyncCoordinator(
      userId: widget.decoyMode ? 'decoy-user' : widget.onionAddress,
      keyManager: widget.keyManager,
      torManager: widget.torManager,
      isTorStopped: () => _torStopped,
    );
    if (!widget.decoyMode) {
      TorOutboundGateway.configure(widget.torManager);
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
        isTorStopped: () => _torStopped,
        showOnlineStatus: () => appSettings.showOnlineStatus,
        onFlushPeer: (peerId) =>
            _syncCoordinator!.flushPendingForPeer(peerId),
      );
    }

    if (widget.decoyMode) {
      return;
    }

    loadUsers().then((_) async {
      if (mounted && !_torStopped) {
        final flushed = await _syncCoordinator!.flushAllPending();
        if (flushed && mounted) {
          scheduleLoadUsers(light: true);
        }
        if (mounted) {
          unawaited(_maybeBroadcastWakeHints(coldStart: true));
        }
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(runDesktopUpdaterCheck());
    });

    _startAutoRefresh();
    _startTorHealthMonitor();
    _batterySaverSub = BatterySaverService.instance.onChanged.listen((_) {
      if (!mounted) return;
      _restartBackgroundIntervals();
    });
    _inboundRefreshSub =
        ConversationRefreshNotifier.instance.onRefresh.listen((_) {
      scheduleLoadUsers(light: true);
    });
    _groupMembershipSub =
        GroupMembershipNotifier.instance.onRemoved.listen((groupId) {
      if (!mounted) return;
      if (selectedConversation is GroupConversation &&
          (selectedConversation as GroupConversation).group.id == groupId) {
        clearChat();
      }
      scheduleLoadUsers(light: true);
    });
    NotificationService.onNotificationTap = _handleNotificationTap;

    if (!Platform.isAndroid && !Platform.isIOS) {
      unawaited(TrayService.instance.start(
        userId: widget.onionAddress,
      ));
    }
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
    if (payload == null || !mounted) return;
    try {
      final data = jsonDecode(payload) as Map<String, dynamic>;
      final groupId = data['groupId'] as String?;
      if (groupId != null) {
        final group = groups.cast<Group?>().firstWhere(
              (g) => g?.id == groupId,
              orElse: () => null,
            );
        if (group != null) {
          onSelectGroup(group);
        }
        return;
      }
      final senderId = data['senderId'] as String?;
      if (senderId == null) return;
      final contact = contacts.cast<Contact?>().firstWhere(
            (c) => c?.id == senderId,
            orElse: () => null,
          );
      if (contact != null) {
        onSelectContact(contact);
      }
    } catch (e) {
      print('Notification tap handler failed: $e');
    }
  }

  @override
  void didUpdateWidget(covariant HomeScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentTheme != widget.currentTheme) {
      setState(() {
        currentTheme = widget.currentTheme;
      });
    }
  }


  void _restartBackgroundIntervals() {
    _refreshTimer?.cancel();
    _startAutoRefresh();
    _startTorHealthMonitor();
    _syncCoordinator?.start();
  }

  void _startAutoRefresh() {
    _refreshTimer?.cancel();
    _refreshTimer = Timer.periodic(BatterySaverPolicy.homeRefreshInterval(), (timer) async {
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
    final groupService =
        GroupService(userId: widget.onionAddress, keyManager: widget.keyManager);
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
      ]);
      if (!mounted) return;
      userMaps = results[0] as List<Map<String, dynamic>>;
      timestamps = results[1] as Map<String, int>;
      newGroups = results[2] as List<Group>;
      previews = results[3] as Map<String, String>;
      unread = results[4] as Map<String, int>;
      prefs = results[5] as Map<String, ConversationPreferences>;
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
      ]);
      if (!mounted) return;
      previews = deferred[0] as Map<String, String>;
      unread = deferred[1] as Map<String, int>;
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
      newContacts.add(Contact(
        id: id,
        name: map['name'] as String,
        avatarUrl: '',
        avatarBase64: map['avatarBase64'] as String?,
        customName: map['customName'] as String?,
        publicKeyPem: (map['publicKeyPem'] as String?) ?? '',
        lastMessageTimestamp: timestamps[id],
      ));
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

    final changed = newContacts.length != contacts.length ||
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
      'publicKeyPem': user.publicKeyPem
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
    });
  }

  void onSelectGroup(Group group) {
    setState(() {
      selectedContact = null;
      selectedConversation = GroupConversation(group);
      showProfile = false;
      showSettings = false;
    });
  }

  void _showCreateGroup() {
    if (widget.decoyMode) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Could not create group. Make sure all members are online and try again.',
          ),
        ),
      );
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CreateGroupScreen(
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

  void onShowProfile() {
    setState(() {
      showSettings = false;
      showProfile = true;
    });
  }

  void onShowSettings() {
    setState(() {
      showSettings = true;
      showProfile = false;
    });
  }

  void onThemeChanged(int themeIndex) {
    setState(() {
      currentTheme = themeIndex;
    });
    widget.onThemeChanged?.call(themeIndex);
  }

  Future<void> _showAddUserDialog({String? prefilledId}) async {
    final idController = TextEditingController(text: prefilledId ?? '');
    final nameController = TextEditingController();
    final hostContext = context;

    Future<void> submit(BuildContext dialogContext) async {
      String newId;
      try {
        newId = decodeBase58ToOnion(idController.text.trim());
      } catch (_) {
        return;
      }
      final newName = nameController.text.trim();

      if (newId.isEmpty || newId == '.onion' || newName.isEmpty) {
        return;
      }
      if (widget.decoyMode) {
        if (!dialogContext.mounted) return;
        ScaffoldMessenger.of(dialogContext).showSnackBar(
          const SnackBar(
            content: Text(
              'Could not reach peer or fetch their public key. '
              'Make sure they are online and try again.',
            ),
          ),
        );
        return;
      }
      final added = await _addNewUser(newId, newName);
      if (!dialogContext.mounted) return;
      if (!added) {
        ScaffoldMessenger.of(dialogContext).showSnackBar(
          const SnackBar(
            content: Text(
              'Could not reach peer or fetch their public key. '
              'Make sure they are online and try again.',
            ),
          ),
        );
        return;
      }
      await loadUsers();
      if (dialogContext.mounted) Navigator.of(dialogContext).pop();
    }

    await showDialog(
      context: hostContext,
      builder: (dialogContext) {
        Future<void> scanQrCode() async {
          Navigator.of(dialogContext).pop();
          final scannedValue = await Navigator.push<String>(
            hostContext,
            MaterialPageRoute(
              builder: (_) => const QrScannerScreen(),
            ),
          );
          if (scannedValue != null && scannedValue.isNotEmpty) {
            _showAddUserDialog(prefilledId: scannedValue);
          }
        }

        return AlertDialog(
        title: const Text('Add contact'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: TextField(
                    controller: idController,
                    autofocus: prefilledId == null,
                    decoration: const InputDecoration(
                      labelText: 'User ID (Base58 Onion URL)',
                      hintText: 'eg. 51EsbujFRDJLHJ',
                    ),
                  ),
                ),
                if (QrPlatform.isScanSupported)
                  IconButton(
                    icon: const Icon(Icons.qr_code_scanner),
                    tooltip: 'Scan QR code',
                    onPressed: scanQrCode,
                  ),
              ],
            ),
            const SizedBox(height: 16),
            TextField(
              controller: nameController,
              autofocus: prefilledId != null,
              decoration: const InputDecoration(
                labelText: 'Display name',
                hintText: 'eg. Alice',
              ),
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => submit(dialogContext),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => submit(dialogContext),
            child: const Text('Add'),
          ),
        ],
        );
      },
    );
  }

  Future<bool> _addNewUser(String id, String name) async {
    return ContactAddService.instance.addContact(
      onionId: id,
      displayName: name,
    );
  }

  String formatLastMessageTime(int? timestamp) {
    if (timestamp == null) return "No message";
    final dt = DateTime.fromMillisecondsSinceEpoch(timestamp).toUtc().toLocal();
    final now = DateTime.now().toUtc();

    bool isSameDay = dt.year == now.year && dt.month == now.month && dt.day == now.day;

    if (isSameDay) {
      // Format as "HH:mm"
      return DateFormat('HH:mm').format(dt);
    } else {
      // Format as "dd/MM/yy - HH:mm"
      return DateFormat('dd/MM/yy - HH:mm').format(dt);
    }
  }


  Widget buildSidebar() { 
    
    final isMobile = MediaQuery.of(context).size.width < 600; // You can tune this breakpoint

    return Container(
      margin: EdgeInsetsGeometry.only(top: isMobile ? 50 : 0, bottom: isMobile ? 20 : 0),
      width: 280,
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        border: Border(
          right: BorderSide(
            color: Theme.of(context).dividerColor.withValues(alpha: 0.1),
            width: 1
          )
        )
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: Theme.of(context).dividerColor.withValues(alpha: 0.1),
                  width: 1
                )
              )
            ),
            child: Row(
              children: [
                ContactAvatar(name: appUser.name, radius: 20, avatarBase64: appUser.avatarBase64),
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
                        )
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _onionPreview(widget.onionAddress),
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).hintColor,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.qr_code, size: 20),
                  tooltip: 'Show my QR code',
                  onPressed: () => showPrysmIdQrDialog(
                    context,
                    encodeOnionToBase58(appUser.id),
                  ),
                ),
                if (QrPlatform.isScanSupported)
                  IconButton(
                    icon: const Icon(Icons.qr_code_scanner, size: 20),
                    tooltip: 'Scan a QR code',
                    onPressed: () async {
                      final scanned = await Navigator.push<String>(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const QrScannerScreen(),
                        ),
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
                  IconButton(
                    icon: const Icon(Icons.arrow_back),
                    tooltip: 'Back to chats',
                    onPressed: () => setState(() {
                      _viewingArchived = false;
                      _searchQuery = '';
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
          const SizedBox(height: 8),
          // Search bar
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Container(
              decoration: BoxDecoration(
                color: Theme.of(context).scaffoldBackgroundColor,
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.05),
                    blurRadius: 4
                  )
                ]
              ),
              child: TextField(
                onChanged: (value) {
                  setState(() => _searchQuery = value.trim().toLowerCase());
                },
                decoration: InputDecoration(
                  hintText: _viewingArchived
                      ? 'Search archived...'
                      : 'Search chats...',
                  hintStyle: const TextStyle(fontSize: 14),
                  prefixIcon: const Icon(Icons.search, size: 20),
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          // Conversation list
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: _filteredConversations.length +
                  (!_viewingArchived && _searchQuery.isEmpty && _archivedCount > 0
                      ? 1
                      : 0),
              itemBuilder: (_, index) {
                final showArchivedEntry = !_viewingArchived &&
                    _searchQuery.isEmpty &&
                    _archivedCount > 0;
                if (showArchivedEntry && index == _filteredConversations.length) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    child: ListTile(
                      leading: Icon(
                        Icons.archive_outlined,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      title: const Text('Archived'),
                      subtitle: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('$_archivedCount'),
                          if (_archivedUnreadCount > 0) ...[
                            const SizedBox(width: 8),
                            Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                color: Theme.of(context).colorScheme.primary,
                                shape: BoxShape.circle,
                              ),
                            ),
                          ],
                        ],
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      onTap: () => setState(() => _viewingArchived = true),
                    ),
                  );
                }

                final conv = _filteredConversations[index];
                final isSelected = selectedConversation?.id == conv.id;
                final prefs = _conversationPrefs[conv.id];
                final isPinned = prefs?.isPinned ?? false;
                final isArchived = prefs?.isArchived ?? false;
                final Widget leading;
                final String subtitle;

                final unreadCount = _unreadCounts[conv.id] ?? 0;
                final preview = _lastMessagePreviews[conv.id];
                final timeLabel = formatLastMessageTime(conv.lastMessageTimestamp);

                if (conv is DirectConversation) {
                  final contact = conv.contact;
                  leading = ContactAvatar(name: contact.displayName, avatarBase64: contact.avatarBase64);
                  subtitle = preview != null ? '$preview · $timeLabel' : timeLabel;
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

                Widget? trailing;
                if (unreadCount > 0) {
                  trailing = CircleAvatar(
                    radius: 11,
                    backgroundColor: Theme.of(context).colorScheme.primary,
                    child: Text(
                      unreadCount > 9 ? '9+' : '$unreadCount',
                      style: TextStyle(
                        fontSize: 10,
                        color: Theme.of(context).colorScheme.onPrimary,
                      ),
                    ),
                  );
                } else if (isPinned && !_viewingArchived) {
                  trailing = Icon(
                    Icons.push_pin,
                    size: 18,
                    color: Theme.of(context).hintColor,
                  );
                }

                return Padding(
                  key: ValueKey('${conv.id}_${conv.lastMessageTimestamp ?? 0}_$unreadCount'),
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  child: ListTile(
                    leading: leading,
                    title: Row(
                      children: [
                        Expanded(
                          child: Text(
                            conv.displayName,
                            style: TextStyle(
                              fontWeight: unreadCount > 0 || isSelected
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (isArchived && !_viewingArchived && _searchQuery.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(left: 4),
                            child: Icon(
                              Icons.archive_outlined,
                              size: 14,
                              color: Theme.of(context).hintColor,
                            ),
                          ),
                      ],
                    ),
                    subtitle: Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: trailing,
                    selected: isSelected,
                    selectedTileColor: Theme.of(context).primaryColor.withValues(alpha: 0.1),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    onTap: () {
                      if (conv is DirectConversation) {
                        onSelectContact(conv.contact);
                      } else if (conv is GroupConversation) {
                        onSelectGroup(conv.group);
                      }
                    },
                    onLongPress: () => _showConversationActions(conv),
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
                  color: Theme.of(context).dividerColor.withValues(alpha: 0.1),
                  width: 1
                ),
              )
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                IconButton(
                  icon: const Icon(Icons.settings_outlined),
                  onPressed: onShowSettings,
                  tooltip: "Settings",
                ),
                IconButton(
                  icon: const Icon(Icons.person_outline),
                  onPressed: onShowProfile,
                  tooltip: "Profile",
                ),
                IconButton(
                  icon: const Icon(Icons.group_add_outlined),
                  onPressed: _showCreateGroup,
                  tooltip: "Create Group",
                ),
                IconButton(
                  icon: const Icon(Icons.add_circle_outline),
                  onPressed: _showAddUserDialog,
                  tooltip: "Add Contact",
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
    WidgetsBinding.instance.removeObserver(this);
    _shutdownTor();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Never stop Tor on `inactive` — that fires on focus loss, dialogs, and
    // notifications, which was causing random shutdowns during normal use.
    // Desktop exit is handled by MyWindowListener; mobile uses `detached`.
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
    _torHealthTimer = Timer.periodic(BatterySaverPolicy.torHealthInterval(), (_) {
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

    if (!mounted) return;

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
      _torStopped = false;
      await widget.torManager.startTor();
      TorOutboundGateway.configure(widget.torManager);
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
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Tor restarted successfully')),
        );
      }
    } catch (e) {
      _torStopped = true;
      if (!mounted) return;
      setState(() {
        _torConnectionState = TorConnectionState.disconnected;
        _torNeedsAttention = false;
      });
      TorConnectionNotifier.instance.update(TorConnectionState.disconnected);
      if (userInitiated) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Tor restart failed: $e')),
        );
      }
    } finally {
      _torRestartInProgress = false;
      if (mounted && !_torStopped) {
        _startTorHealthMonitor();
      }
    }
  }

  void _showTorStatusSheet() {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Tor connection', style: Theme.of(ctx).textTheme.titleLarge),
              const SizedBox(height: 12),
              Row(
                children: [
                  _torStatusDot(_torConnectionState),
                  const SizedBox(width: 8),
                  Expanded(child: Text(_torStatusLabel(_torConnectionState))),
                ],
              ),
              if (_torNeedsAttention) ...[
                const SizedBox(height: 8),
                Text(
                  'Tor needs attention — automatic recovery paused. '
                  'Try Restart Tor manually.',
                  style: Theme.of(ctx).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(ctx).colorScheme.error,
                      ),
                ),
              ],
              if (_torSupervisor?.lastHealthFailureReason != null) ...[
                const SizedBox(height: 8),
                Text(
                  'Last issue: ${_torSupervisor!.lastHealthFailureReason}',
                  style: Theme.of(ctx).textTheme.bodySmall,
                ),
              ],
              if (_torSupervisor != null && _torSupervisor!.autoRestartCount > 0) ...[
                const SizedBox(height: 4),
                Text(
                  'Auto-restarts: ${_torSupervisor!.autoRestartCount}',
                  style: Theme.of(ctx).textTheme.bodySmall,
                ),
              ],
              if (TorOutboundGateway.isConfigured) ...[
                const SizedBox(height: 8),
                Text(
                  'Outbound queue depth: '
                  '${TorOutboundGateway.instance.outboundQueueDepth}',
                  style: Theme.of(ctx).textTheme.bodySmall,
                ),
              ],
              if (!Platform.isAndroid && !Platform.isIOS) ...[
                const SizedBox(height: 4),
                Text(
                  'Health check: '
                  '${widget.torManager.lastHealthPollWasLight ? 'light (SOCKS)' : 'full (control)'}',
                  style: Theme.of(ctx).textTheme.bodySmall,
                ),
              ],
              const SizedBox(height: 8),
              Text(
                'Onion: ${widget.onionAddress}',
                style: Theme.of(ctx).textTheme.bodySmall,
              ),
              if (_torSupervisor != null &&
                  _torSupervisor!.recentStderrLines.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text('Recent Tor log', style: Theme.of(ctx).textTheme.labelLarge),
                const SizedBox(height: 4),
                Container(
                  width: double.infinity,
                  constraints: const BoxConstraints(maxHeight: 120),
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Theme.of(ctx).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: SingleChildScrollView(
                    child: Text(
                      _torSupervisor!.recentStderrLines.join('\n'),
                      style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                            fontFamily: 'monospace',
                            fontSize: 11,
                          ),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _torConnectionState == TorConnectionState.connecting ||
                          _torRestartInProgress
                      ? null
                      : () {
                          Navigator.pop(ctx);
                          _restartTor();
                        },
                  icon: const Icon(Icons.refresh),
                  label: const Text('Restart Tor'),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () async {
                    Navigator.pop(ctx);
                    final ok = await widget.torManager.refreshCircuit();
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          ok ? 'New Tor circuit requested' : 'Circuit refresh failed',
                        ),
                      ),
                    );
                  },
                  icon: const Icon(Icons.swap_horiz),
                  label: const Text('New circuit'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _onionPreview(String onion) {
    final short = onion.replaceAll('.onion', '');
    if (short.length <= 10) return short;
    return '${short.substring(0, 8)}…';
  }

  Color _torStatusColor(TorConnectionState state) => switch (state) {
        TorConnectionState.connected => Colors.green,
        TorConnectionState.connecting => Colors.orange,
        TorConnectionState.disconnected => Colors.red,
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
      TorConnectionState.disconnected => 'Off',
    };

    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: Tooltip(
        message: 'Tor: ${_torStatusLabel(_torConnectionState)}',
        child: Material(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(20),
          child: InkWell(
            onTap: _showTorStatusSheet,
            borderRadius: BorderRadius.circular(20),
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: narrow ? 10 : 12,
                vertical: 8,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.shield_outlined, size: 18, color: color),
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
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Prysm ID copied to clipboard'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  String _truncateId(String id, {int head = 12, int tail = 8}) {
    if (id.length <= head + tail + 3) return id;
    return '${id.substring(0, head)}…${id.substring(id.length - tail)}';
  }

  Widget _buildEmptyHomeState() {
    final theme = Theme.of(context);
    final prysmId = encodeOnionToBase58(appUser.id);
    final contactCount =
        contacts.where((c) => c.id != widget.onionAddress).length;
    final groupCount = groups.length;
    final displayName = appUser.name.isNotEmpty ? appUser.name : 'there';

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            theme.colorScheme.surface,
            theme.colorScheme.primary.withValues(alpha: 0.06),
            theme.colorScheme.surface,
          ],
        ),
      ),
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 40),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  padding: const EdgeInsets.all(28),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      colors: [
                        theme.colorScheme.primary,
                        theme.colorScheme.primary.withValues(alpha: 0.7),
                      ],
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: theme.colorScheme.primary.withValues(alpha: 0.35),
                        blurRadius: 32,
                        offset: const Offset(0, 12),
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.chat_bubble_rounded,
                    size: 56,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 32),
                Text(
                  'Welcome back, $displayName',
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  'Pick a conversation from the sidebar or start a new one.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.hintColor,
                    height: 1.4,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 28),
                Material(
                  color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(16),
                  child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 14,
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.fingerprint_outlined,
                            color: theme.colorScheme.primary,
                            size: 22,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Your Prysm ID',
                                  style: theme.textTheme.labelMedium?.copyWith(
                                    color: theme.hintColor,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  _truncateId(prysmId),
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    fontFamily: 'monospace',
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            icon: Icon(
                              Icons.copy_rounded,
                              size: 20,
                              color: theme.colorScheme.primary,
                            ),
                            tooltip: 'Copy ID',
                            onPressed: _copyPrysmId,
                          ),
                          IconButton(
                            icon: Icon(
                              Icons.qr_code,
                              color: theme.colorScheme.primary,
                            ),
                            tooltip: 'Show full QR code',
                            onPressed: () => showPrysmIdQrDialog(context, prysmId),
                          ),
                          if (QrPlatform.isScanSupported)
                            IconButton(
                              icon: Icon(
                                Icons.qr_code_scanner,
                                color: theme.colorScheme.primary,
                              ),
                              tooltip: 'Scan a QR code',
                              onPressed: () async {
                                final scanned = await Navigator.push<String>(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => const QrScannerScreen(),
                                  ),
                                );
                                if (scanned != null && scanned.isNotEmpty) {
                                  _showAddUserDialog(prefilledId: scanned);
                                }
                              },
                            ),
                        ],
                      ),
                    ),
                ),
                const SizedBox(height: 24),
                Row(
                  children: [
                    Expanded(
                      child: _buildHomeActionCard(
                        icon: Icons.person_add_alt_1_rounded,
                        title: 'Add contact',
                        subtitle: 'Connect via their onion ID',
                        onTap: _showAddUserDialog,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _buildHomeActionCard(
                        icon: Icons.groups_rounded,
                        title: 'Create group',
                        subtitle: 'Up to 5 members',
                        onTap: _showCreateGroup,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                Text(
                  '$contactCount ${contactCount == 1 ? 'contact' : 'contacts'} · $groupCount ${groupCount == 1 ? 'group' : 'groups'}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.hintColor,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHomeActionCard({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);
    return Material(
      color: theme.cardColor,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: theme.dividerColor.withValues(alpha: 0.15),
        ),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: theme.colorScheme.primary, size: 24),
              ),
              const SizedBox(height: 12),
              Text(
                title,
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 15,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
                style: TextStyle(
                  fontSize: 12,
                  color: theme.hintColor,
                  height: 1.3,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _shutdownTor() async {
    if (!_torStopped) {
      _torStopped = true;
      _torHealthTimer?.cancel();
      await widget.torManager.stopTor();
      print('Tor process stopped gracefully.');
    }
  }

  void clearChat() {
    setState(() {
      loadUsers();
      selectedContact = null;
      selectedConversation = null;
    });
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
        torManager: widget.torManager,
        keyManager: widget.decoyMode ? null : widget.keyManager,
        onionAddress: widget.decoyMode ? null : widget.onionAddress,
      );
    }
    if (selectedConversation is GroupConversation) {
      final group = (selectedConversation as GroupConversation).group;
      if (widget.decoyMode) {
        return DecoyChatScreen(
          key: ValueKey('decoy_group_${group.id}'),
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
      );
    }
    if (selectedContact != null) {
      if (widget.decoyMode) {
        final contact = selectedContact!;
        return DecoyChatScreen(
          key: ValueKey('decoy_dm_${contact.id}'),
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
      );
    }
    return _buildEmptyHomeState();
  }

  @override
  Widget build(BuildContext context) {
    final isMobile = MediaQuery.of(context).size.width < 600; // You can tune this breakpoint

    if (isLoading) {
      return const Material(child: Center(child: CircularProgressIndicator()));
    }

    
    if (isMobile) {
       return Scaffold(
        appBar: AppBar(
          toolbarHeight: 70,
          title: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Theme.of(context).primaryColor.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Image.asset(
                  'assets/logo.png',
                  height: 40.0,
                  width: 40.0,
                  fit: BoxFit.contain,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  '${settings.name} Chat',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          leading: Builder(
            builder: (context) => IconButton(
              icon: const Icon(Icons.menu),
              onPressed: () => Scaffold.of(context).openDrawer(),
            )
          ),
          actions: [
            _buildTorAppBarAction(),
            IconButton(
              icon: const Icon(Icons.settings_outlined),
              tooltip: 'Settings',
              onPressed: () => setState(() => showSettings = true),
            ),
          ],
          elevation: 2,
          shadowColor: Colors.black.withValues(alpha: 0.1),
        ),
        drawer: Drawer(
          child: buildSidebar(),
        ),
        body: Row(
          children: [
            Expanded(child: _buildChatBody()),
          ],
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 70,
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Theme.of(context).primaryColor.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Image.asset(
                'assets/logo.png',
                height: 40.0,
                width: 40.0,
                fit: BoxFit.contain,
              ),
            ),
            const SizedBox(width: 12),
            Text(
              '${settings.name} Chat',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
            ),
          ],
        ),
        actions: [
          _buildTorAppBarAction(),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Settings',
            onPressed: () => setState(() => showSettings = true),
          ),
        ],
        elevation: 2,
        shadowColor: Colors.black.withValues(alpha: 0.1),
      ),
      body: Row(
        children: [
          buildSidebar(),
          Expanded(child: _buildChatBody()),
        ],
      ),
    );
  }
}
