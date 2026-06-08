import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:mutex/mutex.dart';
import 'package:prysm/util/tor_bootstrap_notifier.dart';

class TorManager {
  // Desktop-only Tor process.
  Process? _torProcess;

  // Shared control connection.
  Socket? _controlSocket;
  Stream<String>? _controlStream;
  int _controlGeneration = 0;

  static const MethodChannel _channel = MethodChannel("prysm_tor");

  final String torPath;   // desktop tor binary path
  final String dataDir;   // desktop data dir
  final int controlPort;  // 9051
  final int socksPort; // 9050 — used for health checks on desktop
  final String controlPassword; // desktop only

  final stdoutController = StreamController<String>.broadcast();
  final stderrController = StreamController<String>.broadcast();
  final _controlMutex = Mutex();

  TorManager({
    required this.torPath,
    required this.dataDir,
    this.controlPort = 9051,
    this.socksPort = 9050,
    this.controlPassword = 'my_password',
  });

  // =========================
  // Public API
  // =========================

  Future<void> startTor() {
    return _controlMutex.protect(() async {
      TorBootstrapNotifier.instance.reset();
      if (Platform.isAndroid) {
        await _startAndroidTorService();
        return;
      }
      await _startDesktopTorBinary();
    });
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
    return _controlMutex.protect(_stopTorUnlocked);
  }

  Future<void> _stopTorUnlocked() async {
    if (Platform.isAndroid) {
      await _channel.invokeMethod("stopTor");
      await _resetControlSession();
      await Future.delayed(const Duration(milliseconds: 300));
      return;
    }

    // Desktop shutdown via control port if possible.
    try {
      if (_controlSocket != null) {
        await _sendAndCollectImpl(
          'SIGNAL SHUTDOWN',
          untilOk: true,
          timeout: const Duration(seconds: 5),
        );
      }
    } catch (_) {
      // ignore
    }

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
  }

  /// Returns true if the Tor control port responds and the process is alive.
  Future<bool> isHealthy() {
    return _controlMutex.protect(_isHealthyUnlocked);
  }

  Future<bool> _isHealthyUnlocked() async {
    try {
      if (!Platform.isAndroid) {
        final proc = _torProcess;
        if (proc != null) {
          try {
            await proc.exitCode.timeout(const Duration(milliseconds: 50));
            return false;
          } catch (_) {
            // Timeout — process still running.
          }
        }
        return _isDesktopTorOperational();
      }

      await _ensureControlSession();
      await _sendAndCollectImpl(
        'GETINFO version',
        untilOk: true,
        timeout: const Duration(seconds: 3),
      );
      return true;
    } catch (e) {
      print('Tor health check failed: $e');
      await _resetControlSession();
      return false;
    }
  }

  /// Desktop health: SOCKS (what the app uses), then onion service, then control port.
  Future<bool> _isDesktopTorOperational() async {
    if (await _probeSocksPort()) return true;

    final hostnameFile = File('$dataDir/hidden_service/hostname');
    if (hostnameFile.existsSync()) {
      final onion = hostnameFile.readAsStringSync().trim();
      if (onion.endsWith('.onion')) return true;
    }

    return _probeDesktopControlPort();
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

  /// One-shot control port check for desktop (banner drain + auth + GETINFO).
  Future<bool> _probeDesktopControlPort() async {
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

      await readUntilOk(); // post-connect banner
      try {
        writeCmd('AUTHENTICATE "$controlPassword"');
        await readUntilOk();
      } catch (_) {
        writeCmd('AUTHENTICATE $controlPassword');
        await readUntilOk();
      }
      writeCmd('GETINFO version');
      await readUntilOk();
      return true;
    } catch (e) {
      print('Tor desktop probe failed: $e');
      return false;
    } finally {
      await socket?.close();
    }
  }

  /// Request a new Tor circuit via SIGNAL NEWNYM.
  /// Rate-limited by Tor to once every 10 seconds.
  Future<bool> refreshCircuit() {
    return _controlMutex.protect(_refreshCircuitUnlocked);
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
      print('refreshCircuit error: $e');
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

  /// Whether a socket [done] callback should clear the active control session.
  static bool shouldClearControlSessionOnSocketDone(
    int closedGeneration,
    int currentGeneration,
  ) =>
      closedGeneration == currentGeneration;

  // =========================
  // Android implementation
  // =========================

  Future<void> _startAndroidTorService() async {
    // Kotlin side: writes torrc + starts/binds TorService.
    await _channel.invokeMethod("startTor");

    // ControlPort on localhost:9051 inside the same app sandbox.
    await _connectControlPort();

    // Match your Kotlin: PROTOCOLINFO -> COOKIEFILE -> AUTHENTICATE <cookieHex>.
    await _authenticateWithCookieFile();

    // Match your Kotlin: poll status/bootstrap-phase until PROGRESS=100.
    await _waitForBootstrap(timeout: const Duration(minutes: 2));
  }

  Future<void> _authenticateWithCookieFile() async {
    final proto = await _sendAndCollectImpl('PROTOCOLINFO 1', untilOk: true);

    final authLine = proto.firstWhere(
      (l) => l.startsWith('250-AUTH'),
      orElse: () => throw Exception('PROTOCOLINFO missing 250-AUTH: $proto'),
    );

    print('TorService PROTOCOLINFO auth: $authLine'); // debug

    if (authLine.contains('METHODS=NULL')) {
      // Even with METHODS=NULL, send AUTHENTICATE "" before GETINFO. [web:83][web:84]
      final authResp = await _sendAndCollectImpl('AUTHENTICATE ""', untilOk: true);
      print('TorService AUTHENTICATE "" response: $authResp');
      return;
    }

    // Fallback cookie auth if COOKIEFILE present (future-proof).
    final cookiePath = _parseCookieFileFromProtocolInfo(authLine);
    if (cookiePath != null) {
      final cookie = await File(cookiePath).readAsBytes();
      final cookieHex = cookie.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      // ignore: unused_local_variable
      final authResp = await _sendAndCollectImpl('AUTHENTICATE $cookieHex', untilOk: true);
      return;
    }

    throw Exception('Unsupported auth: $authLine');
  }


  String? _parseCookieFileFromProtocolInfo(String authLine) {
    // Tor control-spec: COOKIEFILE="...". [web:49]
    final m = RegExp(r'COOKIEFILE="([^"]+)"').firstMatch(authLine);
    return m?.group(1);
  }

  // =========================
  // Desktop implementation
  // =========================

  Future<void> _startDesktopTorBinary() async {
    final torrcPath = await _writeTorrcDesktop();

    _torProcess = await Process.start(
      torPath,
      ['-f', torrcPath],
      mode: ProcessStartMode.normal,
    );

    _torProcess!.stdout.transform(utf8.decoder).listen(stdoutController.add);
    _torProcess!.stderr.transform(utf8.decoder).listen(stderrController.add);

    await _connectControlPort();
    await _authenticateDesktopPassword();
    await _waitForBootstrap(timeout: const Duration(minutes: 2));
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
    final result = await Process.run(torPath, ['--hash-password', controlPassword]);
    if (result.exitCode != 0) {
      throw Exception('Failed to hash control password: ${result.stderr}');
    }
    final output = (result.stdout as String).split('\n').map((l) => l.trim()).toList();
    return output.firstWhere((l) => l.startsWith('16:'), orElse: () {
      throw Exception('No hashed password line (16:...) in: $output');
    });
  }

  Future<void> _authenticateDesktopPassword() async {
    // Tor control-spec supports password auth when HashedControlPassword is set. [web:49]
    final resp = await _sendAndCollectImpl('AUTHENTICATE "$controlPassword"', untilOk: true);
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
      final resp = await _sendAndCollectImpl('GETINFO status/bootstrap-phase', untilOk: true);

      final line = resp.firstWhere((l) => l.contains('status/bootstrap-phase='), orElse: () => '');
      final m = RegExp(r'PROGRESS=(\d+)').firstMatch(line);
      final progress = m == null ? 0 : int.parse(m.group(1)!);
      TorBootstrapNotifier.instance.update(progress);

      if (progress >= 100) {
        TorBootstrapNotifier.instance.update(100);
        return;
      }

      await Future.delayed(const Duration(milliseconds: 500));
    }

    throw Exception('Tor bootstrap timeout');
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

      // Replies follow SMTP-style 250 success / 5xx error codes. [web:49]
      if (line.startsWith('250 OK') || (!untilOk && line.startsWith('250'))) {
        sub.cancel();
        if (!completer.isCompleted) completer.complete(lines);
      } else if (line.startsWith('5')) {
        sub.cancel();
        if (!completer.isCompleted) completer.completeError('Tor control error: $line');
      }
    });

    _sendControlCommand(cmd);

    return completer.future.timeout(timeout, onTimeout: () async {
      await sub.cancel();
      throw Exception('Timeout waiting for reply to: $cmd (got: $lines)');
    });
  }
}
