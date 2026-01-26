import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

class TorManager {
  // Desktop-only Tor process.
  Process? _torProcess;

  // Shared control connection.
  Socket? _controlSocket;
  Stream<String>? _controlStream;

  static const MethodChannel _channel = MethodChannel("prysm_tor");

  final String torPath;   // desktop tor binary path
  final String dataDir;   // desktop data dir
  final int controlPort;  // 9051
  final String controlPassword; // desktop only

  final stdoutController = StreamController<String>.broadcast();
  final stderrController = StreamController<String>.broadcast();

  TorManager({
    required this.torPath,
    required this.dataDir,
    this.controlPort = 9051,
    this.controlPassword = 'my_password',
  });

  // =========================
  // Public API
  // =========================

  Future<void> startTor() async {
    if (Platform.isAndroid) {
      await _startAndroidTorService();
      return;
    }
    await _startDesktopTorBinary();
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

  Future<void> stopTor() async {
    if (Platform.isAndroid) {
      await _channel.invokeMethod("stopTor");
      return;
    }

    // Desktop shutdown via control port if possible.
    try {
      if (_controlSocket != null) {
        await _sendAndCollect('SIGNAL SHUTDOWN', untilOk: true, timeout: const Duration(seconds: 5));
      }
    } catch (_) {
      // ignore
    }

    await _controlSocket?.close();
    _controlSocket = null;
    _controlStream = null;

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
    final proto = await _sendAndCollect('PROTOCOLINFO 1', untilOk: true);

    final authLine = proto.firstWhere(
      (l) => l.startsWith('250-AUTH'),
      orElse: () => throw Exception('PROTOCOLINFO missing 250-AUTH: $proto'),
    );

    print('TorService PROTOCOLINFO auth: $authLine'); // debug

    if (authLine.contains('METHODS=NULL')) {
      // Even with METHODS=NULL, send AUTHENTICATE "" before GETINFO. [web:83][web:84]
      final authResp = await _sendAndCollect('AUTHENTICATE ""', untilOk: true);
      print('TorService AUTHENTICATE "" response: $authResp');
      return;
    }

    // Fallback cookie auth if COOKIEFILE present (future-proof).
    final cookiePath = _parseCookieFileFromProtocolInfo(authLine);
    if (cookiePath != null) {
      final cookie = await File(cookiePath).readAsBytes();
      final cookieHex = cookie.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      // ignore: unused_local_variable
      final authResp = await _sendAndCollect('AUTHENTICATE $cookieHex', untilOk: true);
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
    final resp = await _sendAndCollect('AUTHENTICATE "$controlPassword"', untilOk: true);
    if (resp.every((l) => !l.startsWith('250'))) {
      throw Exception('Desktop AUTHENTICATE failed: $resp');
    }
  }

  // =========================
  // Shared: ControlPort connect
  // =========================

  Future<void> _connectControlPort() async {
    const maxRetries = 40;
    for (var i = 0; i < maxRetries; i++) {
      try {
        _controlSocket = await Socket.connect(
          '127.0.0.1',
          controlPort,
          timeout: const Duration(seconds: 2),
        );

        _controlStream = _controlSocket!
            .cast<List<int>>()
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .asBroadcastStream();

        _controlSocket!.done.then((_) {
          _controlSocket = null;
          _controlStream = null;
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
      final resp = await _sendAndCollect('GETINFO status/bootstrap-phase', untilOk: true);

      final line = resp.firstWhere((l) => l.contains('status/bootstrap-phase='), orElse: () => '');
      final m = RegExp(r'PROGRESS=(\d+)').firstMatch(line);
      final progress = m == null ? 0 : int.parse(m.group(1)!);

      if (progress >= 100) return;

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

  Future<List<String>> _sendAndCollect(
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
