import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:prysm/app/app_composition.dart';
import 'package:prysm/server/PrysmServer.dart';
import 'package:prysm/transport/transport_provider.dart';
import 'package:prysm/util/battery_saver_policy.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/logging.dart';
import 'package:prysm/util/network_reachability.dart';
import 'package:prysm/util/tor_bootstrap_notifier.dart';
import 'package:prysm/util/tor_connection_notifier.dart';
import 'package:prysm/util/tor_downloader.dart';
import 'package:prysm/util/tor_lifecycle_state.dart';
import 'package:prysm/util/tor_service.dart';
import 'package:prysm/util/tor_supervisor.dart';

/// Result of a successful Tor bootstrap.
class TorInitResult {
  const TorInitResult({required this.torManager, required this.onionAddress});
  final TorManager torManager;
  final String onionAddress;
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
  if (Platform.isAndroid || Platform.isIOS) return '';
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

/// Spawns/configures a [TorManager] for the current platform.
Future<TorManager> createTorManager({bool allowDownload = true}) async {
  final torPath = await _resolveTorBinaryPath(allowDownload: allowDownload);
  final dataDirPath = await _resolveTorDataDir();
  return TorManager(
    torPath: torPath,
    dataDir: dataDirPath,
    controlPassword: 'your_strong_password_here',
  );
}

/// Starts Tor and waits for a hidden-service onion address.
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

/// Owns the Tor connection state machine — start-up connect/retry/offline
/// (previously in `_MyAppState`) and the post-connect health monitor +
/// restart (previously in `_HomeScreenState`) — as a single shared
/// [ChangeNotifier] (Fase 5A extraction of `lib/main.dart`).
///
/// A single instance is created once by `_MyAppState` (composition root)
/// and shared with `HomeScreen`; both `_MyAppState` and `_HomeScreenState`
/// subscribe via [addListener] instead of owning this state themselves.
/// [TorManager] is ctor-injectable (`torManagerFactory`/`torInitializer`)
/// so tests can supply a fake.
class TorConnectionController extends ChangeNotifier {
  TorConnectionController({
    required this.keyManager,
    Future<bool> Function()? hasInternet,
    Future<TorManager> Function({bool allowDownload})? torManagerFactory,
    Future<TorInitResult> Function()? torInitializer,
    this.onConnected,
    this.onReconnected,
    this.onRestartSucceeded,
    this.onRestartFailed,
  }) : _hasInternet = hasInternet ?? NetworkReachability.hasInternet,
       _torManagerFactory = torManagerFactory ?? createTorManager,
       _torInitializer = torInitializer ?? initializeTor {
    _bootstrapSub = TorBootstrapNotifier.instance.onProgress.listen((p) {
      if (!_disposed) {
        bootstrapProgress = p;
        notifyListeners();
      }
    });
  }

  final KeyManager keyManager;
  final Future<bool> Function() _hasInternet;
  final Future<TorManager> Function({bool allowDownload}) _torManagerFactory;
  final Future<TorInitResult> Function() _torInitializer;

  /// Invoked once Tor first connects, for composition-root wiring that
  /// belongs to the app shell (`_globalTorManager`, the desktop window
  /// listener) rather than the connection state machine itself. Set by
  /// `_MyAppState` at construction time.
  void Function(TorInitResult result)? onConnected;

  /// Invoked whenever the connection transitions back to connected after
  /// having been disconnected. Owned by `_HomeScreenState` (flushes sync,
  /// reloads users, broadcasts wake hints) — assigned after construction,
  /// once a `HomeScreen` exists to own it.
  Future<void> Function()? onReconnected;

  /// A user-initiated restart finished or failed. Owned by
  /// `_HomeScreenState` (shows a toast, which needs `BuildContext`) —
  /// assigned after construction, same as [onReconnected].
  void Function()? onRestartSucceeded;
  void Function(Object error)? onRestartFailed;

  bool _disposed = false;
  bool _decoyMode = false;
  StreamSubscription<int>? _bootstrapSub;

  // --- start-up connect state (was _MyAppState) ---
  TorManager? torManager;
  String? onionAddress;
  String status = 'Initializing...';
  bool ready = false;
  bool failed = false;
  bool offline = false;
  bool connecting = false;
  int bootstrapProgress = 0;

  // --- post-connect health/restart state (was _HomeScreenState) ---
  bool torStopped = false;
  bool restartInProgress = false;
  bool needsAttention = false;
  TorConnectionState connectionState = TorConnectionState.connected;
  TorSupervisor? supervisor;
  DateTime? lastDisconnectedAt;
  Timer? _healthTimer;

  Future<void> _notifyReconnected() async {
    final callback = onReconnected;
    if (callback != null) await callback();
  }

  // ---------------------------------------------------------------------
  // Start-up connect / retry / offline
  // ---------------------------------------------------------------------

  Future<void> checkStartupConnectivity() async {
    if (!await _hasInternet()) {
      await enterOfflineMode();
      return;
    }
    await initInBackground();
  }

  Future<void> enterOfflineMode() async {
    final manager = await _torManagerFactory(allowDownload: false);
    final cachedOnion = await manager.getCachedOnionAddress();
    if (_disposed) return;
    torManager = manager;
    onionAddress = cachedOnion;
    offline = true;
    ready = false;
    failed = false;
    connecting = false;
    status = cachedOnion == null || cachedOnion.isEmpty
        ? 'Offline — connect to Tor to get your Prysm ID'
        : 'Offline';
    notifyListeners();
    TorConnectionNotifier.instance.update(TorConnectionState.disconnected);
  }

  Future<void> _applyConnectedResult(TorInitResult result) async {
    AppComposition.wireTorConnected(
      torManager: result.torManager,
      keyManager: keyManager,
    );

    onConnected?.call(result);

    PrysmServer.instance?.localOnionAddress = result.onionAddress;
    TorConnectionNotifier.instance.update(TorConnectionState.connected);
  }

  Future<void> connect() async {
    if (connecting) return;
    if (!await _hasInternet()) {
      if (!_disposed) {
        failed = true;
        status = 'No internet connection detected.';
        notifyListeners();
      }
      return;
    }

    connecting = true;
    failed = false;
    ready = false;
    status = 'Connecting to Tor...';
    notifyListeners();

    try {
      final result = await _torInitializer();
      await _applyConnectedResult(result);
      if (!_disposed) {
        torManager = result.torManager;
        onionAddress = result.onionAddress;
        ready = true;
        offline = false;
        connecting = false;
        failed = false;
        status = 'Connected';
        notifyListeners();
      }
    } catch (e) {
      Logging.error('Tor connection failed: $e', 'Main');
      if (torManager == null) {
        await enterOfflineMode();
      }
      if (!_disposed) {
        connecting = false;
        failed = true;
        offline = true;
        status = 'Failed to connect to Tor. Check your network and try again.';
        notifyListeners();
        TorConnectionNotifier.instance.update(TorConnectionState.disconnected);
      }
    }
  }

  Future<void> initInBackground() async {
    try {
      status = 'Starting Tor...';
      notifyListeners();
      final result = await _torInitializer();
      await _applyConnectedResult(result);

      if (!_disposed) {
        torManager = result.torManager;
        onionAddress = result.onionAddress;
        ready = true;
        offline = false;
        failed = false;
        connecting = false;
        status = 'Connected';
        notifyListeners();
      }
    } catch (e) {
      Logging.error('Tor initialization failed: $e', 'Main');
      if (!_disposed) {
        failed = true;
        connecting = false;
        status = 'Failed to connect to Tor. Check your network and try again.';
        notifyListeners();
        TorConnectionNotifier.instance.update(TorConnectionState.disconnected);
      }
    }
  }

  Future<void> retry() async {
    failed = false;
    ready = false;
    offline = false;
    status = 'Retrying Tor connection...';
    notifyListeners();
    await connect();
  }

  // ---------------------------------------------------------------------
  // Post-connect health monitor + restart
  // ---------------------------------------------------------------------

  /// Starts health monitoring for the already-connected [torManager].
  /// Mirrors the Tor-specific slice of the former
  /// `_HomeScreenState._wireOnlineServices`.
  void startMonitoring({required bool decoyMode}) {
    _decoyMode = decoyMode;
    if (!Platform.isAndroid && !Platform.isIOS) {
      supervisor = TorSupervisor(
        torManager: torManager!,
        isTorStopped: () => torStopped,
        isRestartInProgress: () => restartInProgress,
        performRestart: ({bool userInitiated = false}) =>
            performRestart(userInitiated: userInitiated),
      );
    }
    torStopped = false;
    TorLifecycleNotifier.instance.update(TorLifecycleState.ready);
    connectionState = TorConnectionState.disconnected;
    startHealthMonitor();
    unawaited(_notifyReconnected());
  }

  /// Marks Tor as stopped for an offline-mode HomeScreen session, without
  /// starting the health monitor. Mirrors the `widget.offlineMode` branch
  /// of the former `_HomeScreenState.initState`.
  void markStoppedForOfflineMode() {
    torStopped = true;
    TorLifecycleNotifier.instance.update(TorLifecycleState.stopped);
    connectionState = TorConnectionState.disconnected;
    TorConnectionNotifier.instance.update(TorConnectionState.disconnected);
  }

  void startHealthMonitor() {
    _healthTimer?.cancel();
    if (TorBootstrapNotifier.instance.progress >= 100) {
      connectionState = TorConnectionState.connected;
      TorConnectionNotifier.instance.update(TorConnectionState.connected);
    }
    _healthTimer = Timer.periodic(BatterySaverPolicy.torHealthInterval(), (_) {
      checkHealth();
    });
    checkHealth();
  }

  Future<void> checkHealth() async {
    if (_disposed || restartInProgress) return;
    if (torStopped) {
      if (connectionState != TorConnectionState.disconnected) {
        lastDisconnectedAt = DateTime.now();
        connectionState = TorConnectionState.disconnected;
        needsAttention = false;
        notifyListeners();
        TorConnectionNotifier.instance.update(TorConnectionState.disconnected);
      }
      return;
    }

    TorConnectionState next;
    var attention = false;

    final currentSupervisor = supervisor;
    if (currentSupervisor != null) {
      final evaluation = await currentSupervisor.evaluateHealth();
      attention =
          evaluation.connection == TorConnectionEvaluation.needsAttention;
      next = evaluation.connection == TorConnectionEvaluation.connected
          ? TorConnectionState.connected
          : TorConnectionState.disconnected;
    } else {
      final healthy = await torManager!.isHealthy();
      next = healthy
          ? TorConnectionState.connected
          : TorConnectionState.disconnected;
    }

    if (_disposed ||
        torStopped ||
        restartInProgress ||
        TorLifecycleNotifier.instance.blocked) {
      return;
    }

    final stateChanged = next != connectionState;
    final attentionChanged = attention != needsAttention;
    if (stateChanged || attentionChanged) {
      final wasDisconnected =
          connectionState == TorConnectionState.disconnected;
      if (next == TorConnectionState.disconnected) {
        lastDisconnectedAt = DateTime.now();
      }
      connectionState = next;
      needsAttention = attention;
      notifyListeners();
      if (stateChanged) {
        TorConnectionNotifier.instance.update(next);
        if (wasDisconnected && next == TorConnectionState.connected) {
          unawaited(_notifyReconnected());
        }
      }
    }
  }

  /// Restarts Tor, preferring the [TorSupervisor] (desktop) when present.
  Future<void> restart() async {
    if (_disposed || restartInProgress) return;
    final currentSupervisor = supervisor;
    if (currentSupervisor != null) {
      await currentSupervisor.restartTor(userInitiated: true);
    } else {
      await performRestart(userInitiated: true);
    }
  }

  Future<void> performRestart({bool userInitiated = false}) async {
    if (_disposed || restartInProgress) return;

    restartInProgress = true;
    _healthTimer?.cancel();
    torStopped = true;
    TorLifecycleNotifier.instance.update(TorLifecycleState.restarting);

    if (!_decoyMode && TransportProvider.isConfigured) {
      TransportProvider.instance.wsManager.prepareForTorReconnect();
    }

    connectionState = TorConnectionState.connecting;
    needsAttention = false;
    notifyListeners();
    TorConnectionNotifier.instance.update(TorConnectionState.connecting);

    try {
      TorBootstrapNotifier.instance.reset();
      TorLifecycleNotifier.instance.update(TorLifecycleState.bootstrapping);
      await torManager!.restartTor();
      torStopped = false;
      TorLifecycleNotifier.instance.update(TorLifecycleState.ready);
      final onion = await torManager!.getOnionAddress();
      if (onion != null && onion.isNotEmpty) {
        PrysmServer.instance?.localOnionAddress = onion;
      }
      if (_disposed) return;
      connectionState = TorConnectionState.connected;
      needsAttention = false;
      notifyListeners();
      TorConnectionNotifier.instance.update(TorConnectionState.connected);
      await _notifyReconnected();
      if (userInitiated) onRestartSucceeded?.call();
    } catch (e) {
      torStopped = true;
      TorLifecycleNotifier.instance.update(TorLifecycleState.stopped);
      if (_disposed) return;
      connectionState = TorConnectionState.disconnected;
      needsAttention = false;
      notifyListeners();
      TorConnectionNotifier.instance.update(TorConnectionState.disconnected);
      if (userInitiated) onRestartFailed?.call(e);
    } finally {
      restartInProgress = false;
      if (!_disposed && !torStopped) {
        startHealthMonitor();
      }
    }
  }

  Future<void> shutdown() async {
    if (!torStopped) {
      torStopped = true;
      TorLifecycleNotifier.instance.update(TorLifecycleState.stopped);
      _healthTimer?.cancel();
      await torManager!.stopTor();
      Logging.info('Tor process stopped gracefully.', 'Main');
    }
  }

  /// Cancels the health timer and disposes the supervisor without tearing
  /// down the whole controller — mirrors the Tor-specific slice of the
  /// former `_HomeScreenState.dispose()` (HomeScreen may unmount before
  /// the app-level `_MyAppState` that owns this controller does).
  void stopMonitoring() {
    _healthTimer?.cancel();
    supervisor?.dispose();
  }

  /// Detaches the `_HomeScreenState`-owned callbacks ([onReconnected],
  /// [onRestartSucceeded], [onRestartFailed]) so a disposed `HomeScreen`
  /// can never be invoked through them again. The controller is owned by
  /// `_MyAppState` and can outlive `HomeScreen` — any health-monitor tick
  /// or in-flight restart that resolves after `HomeScreen.dispose()` must
  /// find these callbacks gone rather than call back into a disposed
  /// `State`. Symmetric with the assignment in
  /// `_HomeScreenState.initState`; callers should invoke this from
  /// `_HomeScreenState.dispose()`.
  void clearReconnectCallbacks() {
    onReconnected = null;
    onRestartSucceeded = null;
    onRestartFailed = null;
  }

  @override
  void dispose() {
    _disposed = true;
    _bootstrapSub?.cancel();
    stopMonitoring();
    super.dispose();
  }
}
