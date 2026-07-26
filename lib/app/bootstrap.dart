import 'dart:io';

import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/logging.dart';

/// Checks whether a process with [pid] is still alive (best-effort, per
/// platform). Moved verbatim from `main._isProcessRunning` (Fase 5B) — the
/// default collaborator wired into [SingleInstanceGuard] by `main.dart`.
Future<bool> isProcessRunning(int pid) async {
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

/// Desktop single-instance lock-file guard.
///
/// Extracted from `main._runMainApp` (Fase 5B): same exists -> read pid ->
/// is-it-alive -> (exit | write pid and continue) branch, now testable via
/// closure injection instead of touching the real filesystem/process table
/// — style: `test/main_startup_platform_test.dart`.
class SingleInstanceGuard {
  final Future<bool> Function(String path) fileExists;
  final Future<String> Function(String path) readFile;
  final Future<bool> Function(int pid) checkProcessRunning;
  final Future<void> Function(String path, String pid) writeFile;

  const SingleInstanceGuard({
    required this.fileExists,
    required this.readFile,
    required this.checkProcessRunning,
    required this.writeFile,
  });

  /// Returns the PID of another live instance already holding
  /// [lockFilePath], or `null` if none was found — in which case the lock
  /// file has been (re)written with [currentPid] and this process may
  /// proceed as the sole instance.
  Future<int?> detectRunningInstance({
    required String lockFilePath,
    required String currentPid,
  }) async {
    if (await fileExists(lockFilePath)) {
      final otherPid = int.tryParse((await readFile(lockFilePath)).trim());
      if (otherPid != null && await checkProcessRunning(otherPid)) {
        return otherPid;
      }
    }
    await writeFile(lockFilePath, currentPid);
    return null;
  }
}

/// What `main.dart` needs, after [AppBootstrap.initializeServices], to
/// build and show the root widget.
class MainAppBootstrapResult {
  final KeyManager keyManager;
  final String? startupError;
  final bool serverBindFailed;

  const MainAppBootstrapResult({
    required this.keyManager,
    this.startupError,
    this.serverBindFailed = false,
  });
}

typedef BootstrapStep = Future<void> Function();

/// Service init + server start + desktop window show sequence for the main
/// (non-detached) app entry point — as opposed to a detached chat window,
/// see `util/app_bootstrap.dart`'s `bootstrapApp` routing.
///
/// Extracted from `main._runMainApp` (Fase 5B): every step below is a
/// line-for-line port, same order, same try/catch scoping (only the
/// BlockService init and the server start are allowed to fail without
/// aborting startup). `main.dart` now only wires the real collaborators in.
class AppBootstrap {
  const AppBootstrap._();

  /// Settings -> PeerTransportRegistry -> BatterySaver -> NotificationMute
  /// -> BlockService (best-effort) -> server start (best-effort).
  static Future<MainAppBootstrapResult> initializeServices({
    required KeyManager keyManager,
    required BootstrapStep initSettings,
    required BootstrapStep initPeerTransportRegistry,
    required BootstrapStep initBatterySaver,
    required BootstrapStep initNotificationMute,
    required BootstrapStep initBlockService,
    required BootstrapStep startServer,
  }) async {
    await initSettings();
    await initPeerTransportRegistry();
    await initBatterySaver();
    await initNotificationMute();

    String? startupError;
    try {
      await initBlockService();
    } catch (e, st) {
      Logging.error('BlockService init failed: $e\n$st', 'Main');
      startupError = e.toString();
    }

    var serverBindFailed = false;
    try {
      await startServer();
    } catch (e, st) {
      Logging.error('PrysmServer start failed: $e\n$st', 'Main');
      serverBindFailed = true;
    }

    return MainAppBootstrapResult(
      keyManager: keyManager,
      startupError: startupError,
      serverBindFailed: serverBindFailed,
    );
  }

  /// Desktop window show sequence, run from the first post-frame callback:
  /// ensureInitialized -> setTitleBarStyle -> show -> focus -> tray init.
  static Future<void> showDesktopWindow({
    required BootstrapStep ensureInitialized,
    required BootstrapStep setTitleBarStyle,
    required BootstrapStep show,
    required BootstrapStep focus,
    required BootstrapStep initTray,
  }) async {
    await ensureInitialized();
    await setTitleBarStyle();
    await show();
    await focus();
    await initTray();
  }
}
