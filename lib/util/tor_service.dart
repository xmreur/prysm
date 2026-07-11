import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:mutex/mutex.dart';
import 'package:prysm/util/logging.dart';
import 'package:prysm/util/tor_bootstrap_notifier.dart';
import 'package:prysm/util/tor_health_status.dart';

class TorManager {
  // Desktop-only Tor process.
  Process? _torProcess;
  int _processGeneration = 0;

  // Shared control connection.
  Socket? _controlSocket;
  Stream<String>? _controlStream;
  int _controlGeneration = 0;

  static const MethodChannel _channel = MethodChannel("prysm_tor");
  static const int _stderrLineLimit = 20;
  static const Duration restartSettleDelay = Duration(milliseconds: 800);

  final String torPath;
  final String dataDir;
  final int controlPort;
  int _socksPort;
  final String controlPassword;

  int get socksPort => _socksPort;

  void updateSocksPort(int port) {
    if (port > 0 && port <= 65535) {
      _socksPort = port;
    }
  }

  final stdoutController = StreamController<String>.broadcast();
  final stderrController = StreamController<String>.broadcast();
  final _controlReadMutex = Mutex();
  final _controlWriteMutex = Mutex();
  final List<String> _recentStderrLines = [];
  int _healthPollCount = 0;
  static const int _fullHealthEvery = 4;

  /// Set when desktop Tor finishes bootstrap (used for restart grace).
  DateTime? lastStartAt;

  /// Desktop-only: fired when the tor child process exits.
  void Function(int exitCode)? onDesktopProcessExited;

  TorManager({
    required this.torPath,
    required this.dataDir,
    this.controlPort = 9051,
    int socksPort = 9050,
    this.controlPassword = 'my_password',
  }) : _socksPort = socksPort;

  List<String> get recentStderrLines => List.unmodifiable(_recentStderrLines);

  // =========================
  // Public API
  // =========================

  Future<void> startTor() {
    return _controlWriteMutex.protect(() async {
      TorBootstrapNotifier.instance.reset();
      if (Platform.isAndroid) {
        await _startAndroidTorService();
        return;
      }
      await _cleanupOrphanTorBeforeStart();
      await _startDesktopTorBinary();
    });
  }

  Future<String?> getCachedOnionAddress() async {
    if (Platform.isAndroid) {
      try {
        return await _channel.invokeMethod<String>("getCachedOnionAddress");
      } catch (_) {
        return null;
      }
    }

    final hostnameFile = File('$dataDir/hidden_service/hostname');
    if (!hostnameFile.existsSync()) return null;
    return hostnameFile.readAsStringSync().trim();
  }

  Future<String?> getOnionAddress() async {
    if (Platform.isAndroid) {
      try {
        return await _channel.invokeMethod<String>("getOnionAddress");
      } catch (_) {
        return null;
      }
    }

    final hostnameFile = File('$dataDir/hidden_service/hostname');
    if (!hostnameFile.existsSync()) return null;
    return hostnameFile.readAsStringSync().trim();
  }

  Future<void> stopTor() {
    return _controlWriteMutex.protect(_stopTorUnlocked);
  }

  Future<void> _stopTorUnlocked() async {
    if (Platform.isAndroid) {
      await _channel.invokeMethod("stopTor");
      await _resetControlSession();
      await Future.delayed(const Duration(milliseconds: 300));
      return;
    }

    try {
      if (_controlSocket != null) {
        await _sendAndCollectImpl(
          'SIGNAL SHUTDOWN',
          untilOk: true,
          timeout: const Duration(seconds: 5),
        );
      }
    } catch (_) {}

    await _resetControlSession();

    if (_torProcess != null) {
      try {
        _torProcess!.kill(ProcessSignal.sigterm);
        await _torProcess!.exitCode.timeout(const Duration(seconds: 5));
      } catch (_) {
        try {
          _torProcess!.kill(ProcessSignal.sigkill);
          await _torProcess!.exitCode.timeout(const Duration(seconds: 5));
        } catch (_) {}
      }
      _torProcess = null;
    }

    await _removePidFile();
  }

  Future<TorHealthStatus> getHealthStatus() {
    return _getHealthStatusUnlocked();
  }

  Future<bool> isHealthy() async {
    return (await getHealthStatus()).ok;
  }

  Future<TorHealthStatus> _getHealthStatusUnlocked() async {
    try {
      if (!Platform.isAndroid) {
        final proc = _torProcess;
        if (proc == null) {
          return const TorHealthStatus(
            ok: false,
            reason: 'Tor process not running',
          );
        }
        try {
          await proc.exitCode.timeout(const Duration(milliseconds: 50));
          return const TorHealthStatus(
            ok: false,
            reason: 'Tor process exited',
          );
        } catch (_) {}

        if (!await _probeSocksPort()) {
          return const TorHealthStatus(
            ok: false,
            reason: 'SOCKS port unreachable',
          );
        }

        _healthPollCount++;
        if (_healthPollCount % _fullHealthEvery != 0) {
          return TorHealthStatus.healthy;
        }

        return _controlReadMutex.protect(_checkDesktopControlHealth);
      }

      return _controlReadMutex.protect(() async {
        if (!await _probeSocksPort()) {
          return const TorHealthStatus(
            ok: false,
            reason: 'SOCKS port unreachable',
          );
        }
        return TorHealthStatus.healthy;
      });
    } catch (e) {
      Logging.error('Tor health check failed: $e', 'TorManager');
      await _resetControlSession();
      return TorHealthStatus(ok: false, reason: e.toString());
    }
  }

  /// Whether the most recent health poll used SOCKS-only (no control port).
  bool get lastHealthPollWasLight =>
      _healthPollCount > 0 && _healthPollCount % _fullHealthEvery != 0;

  Future<TorHealthStatus> _checkDesktopControlHealth() async {
    try {
      return await _desktopControlHealthViaEphemeral();
    } catch (_) {
      try {
        return await _desktopControlHealthViaEphemeral();
      } catch (retryError) {
        return TorHealthStatus(
          ok: false,
          reason: 'Control check failed: $retryError',
        );
      }
    }
  }

  Future<TorHealthStatus> _desktopControlHealthViaEphemeral() async {
    final bootstrap = await _ephemeralControlCommand(
      'GETINFO status/bootstrap-phase',
      timeout: const Duration(seconds: 3),
    );
    final progress = parseBootstrapProgress(bootstrap) ?? 0;
    if (progress < 100) {
      return TorHealthStatus(
        ok: false,
        reason: 'Tor bootstrap incomplete ($progress%)',
      );
    }

    final liveness = await _ephemeralControlCommand(
      'GETINFO network-liveness',
      timeout: const Duration(seconds: 3),
    );
    if (!isNetworkLive(liveness)) {
      return const TorHealthStatus(ok: false, reason: 'Tor network down');
    }

    return TorHealthStatus.healthy;
  }

  Future<List<String>> _ephemeralControlCommand(
    String cmd, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    Socket? socket;
    try {
      socket = await Socket.connect(
        '127.0.0.1',
        controlPort,
        timeout: const Duration(seconds: 2),
      );

      final iterator = StreamIterator<String>(
        socket
            .cast<List<int>>()
            .transform(utf8.decoder)
            .transform(const LineSplitter()),
      );

      Future<List<String>> readUntilOk() async {
        final lines = <String>[];
        while (await iterator.moveNext()) {
          final line = iterator.current;
          lines.add(line);
          if (line.startsWith('250 OK')) return lines;
          if (line.startsWith('5')) {
            throw Exception('Tor control error: $line');
          }
        }
        throw Exception('Tor control stream closed');
      }

      void writeCmd(String command) => socket!.write('$command\r\n');

      await readUntilOk();
      if (Platform.isAndroid) {
        throw UnsupportedError('Ephemeral control is desktop-only');
      }
      try {
        writeCmd('AUTHENTICATE "$controlPassword"');
        await readUntilOk();
      } catch (_) {
        writeCmd('AUTHENTICATE $controlPassword');
        await readUntilOk();
      }

      writeCmd(cmd);
      return readUntilOk().timeout(timeout);
    } finally {
      await socket?.close();
    }
  }

  Future<bool> _probeSocksPort() async {
    try {
      final socket = await Socket.connect(
        '127.0.0.1',
        socksPort,
        timeout: const Duration(seconds: 2),
      );
      await socket.close();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> refreshCircuit() {
    return _controlWriteMutex.protect(_refreshCircuitUnlocked);
  }

  Future<bool> _refreshCircuitUnlocked() async {
    try {
      await _ensureControlSession();
      await _sendAndCollectImpl(
        'SIGNAL NEWNYM',
        untilOk: true,
        timeout: const Duration(seconds: 5),
      );
      return true;
    } catch (e) {
      Logging.error('refreshCircuit error: $e', 'TorManager');
      await _resetControlSession();
      return false;
    }
  }

  Future<void> _ensureControlSession() async {
    if (_controlSocket != null) return;
    await _connectControlPort();
    if (Platform.isAndroid) {
      await _authenticateWithCookieFile();
    } else {
      await _authenticateDesktopPassword();
    }
  }

  Future<void> _resetControlSession() async {
    _controlGeneration++;
    await _controlSocket?.close();
    _controlSocket = null;
    _controlStream = null;
  }

  static bool shouldClearControlSessionOnSocketDone(
    int closedGeneration,
    int currentGeneration,
  ) =>
      closedGeneration == currentGeneration;

  static bool shouldHandleProcessExit(
    int exitedGeneration,
    int currentGeneration,
    Process? activeProcess,
    Process? exitedProcess,
  ) =>
      exitedGeneration == currentGeneration && activeProcess == exitedProcess;

  // =========================
  // Android implementation
  // =========================

  Future<void> _startAndroidTorService() async {
    await _channel.invokeMethod("startTor");
    await _connectControlPort();
    await _authenticateWithCookieFile();
    await _waitForBootstrap(timeout: const Duration(minutes: 2));
    await _discoverSocksPort();
  }

  Future<void> _authenticateWithCookieFile() async {
    final proto = await _sendAndCollectImpl('PROTOCOLINFO 1', untilOk: true);

    final authLine = proto.firstWhere(
      (l) => l.startsWith('250-AUTH'),
      orElse: () => throw Exception('PROTOCOLINFO missing 250-AUTH: $proto'),
    );

    if (authLine.contains('METHODS=NULL')) {
      await _sendAndCollectImpl('AUTHENTICATE ""', untilOk: true);
      return;
    }

    final cookiePath = _parseCookieFileFromProtocolInfo(authLine);
    if (cookiePath != null) {
      final cookie = await File(cookiePath).readAsBytes();
      final cookieHex =
          cookie.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      await _sendAndCollectImpl('AUTHENTICATE $cookieHex', untilOk: true);
      return;
    }

    throw Exception('Unsupported auth: $authLine');
  }

  String? _parseCookieFileFromProtocolInfo(String authLine) {
    final m = RegExp(r'COOKIEFILE="([^"]+)"').firstMatch(authLine);
    return m?.group(1);
  }

  // =========================
  // Desktop implementation
  // =========================

  Future<void> _cleanupOrphanTorBeforeStart() async {
    Logging.debug('tor cleanup: probing control port...', 'TorManager');
    final found = await _probeOurControlPort();
    Logging.debug('tor cleanup: control port probe = $found', 'TorManager');
    if (found) {
      try {
        await _connectControlPort();
        await _authenticateDesktopPassword();
        Logging.debug('tor cleanup: sending SIGNAL SHUTDOWN...', 'TorManager');
        await _sendAndCollectImpl(
          'SIGNAL SHUTDOWN',
          untilOk: true,
          timeout: const Duration(seconds: 5),
        );
        await _resetControlSession();
        await _pollPortReleased();
        Logging.debug('tor cleanup: SIGNAL SHUTDOWN done', 'TorManager');
      } catch (e) {
        Logging.error('tor cleanup: SIGNAL SHUTDOWN failed: $e', 'TorManager');
        await _resetControlSession();
      }
    }
    await _killOrphanTorForce();
    await _removePidFile();
  }

  Future<void> _killOrphanTorForce() async {
    try {
      if (Platform.isLinux || Platform.isMacOS) {
        final r1 = await Process.run(
          'pkill',
          ['-9', '-f', 'tor.*$dataDir/torrc'],
        );
        Logging.debug('tor cleanup: pkill targeted exit ${r1.exitCode}', 'TorManager');
        if (r1.exitCode != 0) {
          final r2 = await Process.run('pkill', ['-9', 'tor']);
          Logging.debug('tor cleanup: pkill broad exit ${r2.exitCode}', 'TorManager');
        }
      } else if (Platform.isWindows) {
        await Process.run('taskkill', ['/F', '/IM', 'tor.exe']);
      }
      await Future.delayed(const Duration(milliseconds: 500));
    } catch (e) {
      Logging.error('tor cleanup force error: $e', 'TorManager');
    }
  }

  Future<void> _pollPortReleased() async {
    for (var i = 0; i < 10; i++) {
      try {
        final s = await Socket.connect(
          '127.0.0.1', controlPort,
          timeout: const Duration(milliseconds: 200),
        );
        await s.close();
        await Future.delayed(const Duration(milliseconds: 200));
      } catch (_) {
        return;
      }
    }
  }

  Future<bool> _probeOurControlPort() async {
    Socket? socket;
    try {
      socket = await Socket.connect(
        '127.0.0.1',
        controlPort,
        timeout: const Duration(seconds: 2),
      );

      final iterator = StreamIterator<String>(
        socket
            .cast<List<int>>()
            .transform(utf8.decoder)
            .transform(const LineSplitter()),
      );

      Future<void> readUntilOk() async {
        while (await iterator.moveNext()) {
          final line = iterator.current;
          if (line.startsWith('250 OK')) return;
          if (line.startsWith('5')) {
            throw Exception('Tor control error: $line');
          }
        }
        throw Exception('Tor control stream closed');
      }

      void writeCmd(String cmd) => socket!.write('$cmd\r\n');

      await readUntilOk().timeout(const Duration(seconds: 3));
      try {
        writeCmd('AUTHENTICATE "$controlPassword"');
        await readUntilOk().timeout(const Duration(seconds: 3));
      } catch (_) {
        writeCmd('AUTHENTICATE $controlPassword');
        await readUntilOk().timeout(const Duration(seconds: 3));
      }
      return true;
    } catch (_) {
      return false;
    } finally {
      await socket?.close();
    }
  }

  Future<void> _startDesktopTorBinary() async {
    final torrcPath = await _writeTorrcDesktop();
    final processGeneration = ++_processGeneration;

    _torProcess = await Process.start(
      torPath,
      ['-f', torrcPath],
      mode: ProcessStartMode.normal,
    );

    final proc = _torProcess!;
    await _writePidFile(proc.pid);

    proc.stdout.transform(utf8.decoder).listen(stdoutController.add);
    proc.stderr.transform(utf8.decoder).listen(_recordStderrLine);

    proc.exitCode.then((code) {
      if (shouldHandleProcessExit(
        processGeneration,
        _processGeneration,
        _torProcess,
        proc,
      )) {
        _torProcess = null;
        onDesktopProcessExited?.call(code);
      }
    });

    await _connectControlPort();
    await _authenticateDesktopPassword();
    await _waitForBootstrap(timeout: const Duration(minutes: 2));
    await _discoverSocksPort();
  }

  void _recordStderrLine(String line) {
    stderrController.add(line);
    if (line.trim().isEmpty) return;
    _recentStderrLines.add(line);
    if (_recentStderrLines.length > _stderrLineLimit) {
      _recentStderrLines.removeAt(0);
    }
  }

  Future<void> _writePidFile(int pid) async {
    try {
      await File('$dataDir/tor.pid').writeAsString('$pid');
    } catch (_) {}
  }

  Future<void> _removePidFile() async {
    try {
      final file = File('$dataDir/tor.pid');
      if (file.existsSync()) await file.delete();
    } catch (_) {}
  }

  Future<String> _writeTorrcDesktop() async {
    final dir = Directory(dataDir);
    if (!dir.existsSync()) dir.createSync(recursive: true);

    final torrcFile = File('$dataDir/torrc');
    final hashedPassword = await _hashControlPasswordDesktop();

    final torrcContent = '''
ControlPort $controlPort
SocksPort $socksPort
DataDirectory $dataDir
HashedControlPassword $hashedPassword
CookieAuthentication 0
HiddenServiceDir $dataDir/hidden_service/
HiddenServicePort 80 127.0.0.1:12345
''';

    await torrcFile.writeAsString(torrcContent);
    return torrcFile.path;
  }

  Future<String> _hashControlPasswordDesktop() async {
    final cacheFile = File('$dataDir/.control_hash');
    if (cacheFile.existsSync()) {
      final cached = cacheFile.readAsStringSync().trim();
      if (cached.startsWith('16:')) return cached;
    }

    final result =
        await Process.run(torPath, ['--hash-password', controlPassword]);
    if (result.exitCode != 0) {
      throw Exception('Failed to hash control password: ${result.stderr}');
    }
    final output =
        (result.stdout as String).split('\n').map((l) => l.trim()).toList();
    final hash = output.firstWhere((l) => l.startsWith('16:'), orElse: () {
      throw Exception('No hashed password line (16:...) in: $output');
    });
    try {
      await cacheFile.writeAsString(hash);
    } catch (_) {}
    return hash;
  }

  Future<void> _authenticateDesktopPassword() async {
    final resp =
        await _sendAndCollectImpl('AUTHENTICATE "$controlPassword"', untilOk: true);
    if (resp.every((l) => !l.startsWith('250'))) {
      throw Exception('Desktop AUTHENTICATE failed: $resp');
    }
  }

  // =========================
  // Shared: ControlPort connect
  // =========================

  Future<void> _connectControlPort() async {
    await _resetControlSession();

    const maxRetries = 40;
    for (var i = 0; i < maxRetries; i++) {
      try {
        final socket = await Socket.connect(
          '127.0.0.1',
          controlPort,
          timeout: const Duration(seconds: 2),
        );

        final generation = ++_controlGeneration;
        _controlSocket = socket;
        _controlStream = socket
            .cast<List<int>>()
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .asBroadcastStream();

        socket.done.then((_) {
          if (shouldClearControlSessionOnSocketDone(
            generation,
            _controlGeneration,
          )) {
            _controlSocket = null;
            _controlStream = null;
          }
        });

        return;
      } catch (_) {
        await Future.delayed(const Duration(milliseconds: 300));
      }
    }
    throw Exception('Unable to connect to ControlPort $controlPort');
  }

  // =========================
  // Shared: Bootstrap wait
  // =========================

  Future<void> _waitForBootstrap({required Duration timeout}) async {
    final deadline = DateTime.now().add(timeout);

    while (DateTime.now().isBefore(deadline)) {
      final resp = await _sendAndCollectImpl(
        'GETINFO status/bootstrap-phase',
        untilOk: true,
      );

      final progress = parseBootstrapProgress(resp) ?? 0;
      TorBootstrapNotifier.instance.update(progress);

      if (progress >= 100) {
        TorBootstrapNotifier.instance.update(100);
        lastStartAt = DateTime.now();
        return;
      }

      await Future.delayed(const Duration(milliseconds: 500));
    }

    throw Exception('Tor bootstrap timeout');
  }

  Future<void> _discoverSocksPort() async {
    try {
      final resp = await _sendAndCollectImpl(
        'GETINFO net/listeners/socks',
        untilOk: true,
        timeout: const Duration(seconds: 5),
      );
      for (final line in resp) {
        if (!line.startsWith('250-net/listeners/socks=')) continue;
        final match = RegExp(r'"[^"]*:(\d+)"').firstMatch(line);
        if (match != null) {
          updateSocksPort(int.parse(match.group(1)!));
          return;
        }
      }
    } catch (e) {
      Logging.error('SOCKS port discovery failed, using $_socksPort: $e', 'TorManager');
    }
  }

  // =========================
  // Shared: Control helpers
  // =========================

  void _sendControlCommand(String cmd) {
    final sock = _controlSocket;
    if (sock == null) throw Exception('Control socket not connected');
    sock.write('$cmd\r\n');
  }

  Future<List<String>> _sendAndCollectImpl(
    String cmd, {
    required bool untilOk,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final stream = _controlStream;
    if (stream == null) throw Exception('Control stream not ready');

    final lines = <String>[];
    final completer = Completer<List<String>>();
    late final StreamSubscription<String> sub;

    sub = stream.listen((line) {
      lines.add(line);

      if (line.startsWith('250 OK') || (!untilOk && line.startsWith('250'))) {
        sub.cancel();
        if (!completer.isCompleted) completer.complete(lines);
      } else if (line.startsWith('5')) {
        sub.cancel();
        if (!completer.isCompleted) {
          completer.completeError('Tor control error: $line');
        }
      }
    });

    _sendControlCommand(cmd);

    return completer.future.timeout(timeout, onTimeout: () async {
      await sub.cancel();
      throw Exception('Timeout waiting for reply to: $cmd (got: $lines)');
    });
  }
}
