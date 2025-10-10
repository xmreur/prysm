import 'dart:async';
import 'dart:convert';
import 'dart:io';

class TorManager {
  Process? _torProcess;
  Socket? _controlSocket;
  late Stream<String> _controlStream;

  final String torPath;
  final String dataDir;
  final int controlPort;
  final String controlPassword;

  StreamController<String> stdoutController = StreamController.broadcast();
  StreamController<String> stderrController = StreamController.broadcast();

  TorManager({
    required this.torPath,
    required this.dataDir,
    this.controlPort = 9051,
    this.controlPassword = 'my_password',
  });

  /// Launch Tor process with control port enabled
  Future<void> startTor() async {
    final torrcPath = await _writeTorrc();

    _torProcess = await Process.start(
      torPath,
      ['-f', torrcPath],
      mode: ProcessStartMode.normal,
    );

    _torProcess!.stdout.transform(utf8.decoder).listen((data) {
      stdoutController.add(data);
      //print('[Tor] stdout: $data');
    });

    _torProcess!.stderr.transform(utf8.decoder).listen((data) {
      stderrController.add(data);
      //print('[Tor] stderr: $data');
    });

    await _connectControlPort();

    //print('Tor process started and authenticated.');
  }

  /// Write torrc config file for persistent hidden service
  Future<String> _writeTorrc() async {
    final dir = Directory(dataDir);
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }

    final torrcFile = File('$dataDir/torrc');

    final hashedPassword = await _hashControlPassword();

    final torrcContent = '''
ControlPort $controlPort
DataDirectory $dataDir
HashedControlPassword $hashedPassword
CookieAuthentication 0
HiddenServiceDir $dataDir/hidden_service/
HiddenServicePort 12345 127.0.0.1:12345
''';

    await torrcFile.writeAsString(torrcContent);
    return torrcFile.path;
  }

  /// Hash control password using Tor binary
  Future<String> _hashControlPassword() async {
    final result = await Process.run(torPath, ['--hash-password', controlPassword]);
    if (result.exitCode != 0) {
      throw Exception('Failed to hash control password: ${result.stderr}');
    }
    final output = result.stdout as String;
    final hashLine = output.split('\n').firstWhere((line) => line.startsWith('16:'));
    return hashLine;
  }

  /// Connect to Tor control port and authenticate
  Future<void> _connectControlPort() async {
    const maxRetries = 20;
    int retries = 0;

    while (retries < maxRetries) {
      try {
        _controlSocket = await Socket.connect('127.0.0.1', controlPort);
        //print('Connected to Tor ControlPort on $controlPort');

        _controlStream = _controlSocket!
            .cast<List<int>>()
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .asBroadcastStream();

        _controlSocket!.done.then((_) {
          //print('Tor ControlPort socket closed');
          _controlSocket = null;
        });

        await _authenticate();
        return;
      } catch (e) {
        retries++;
        //print('Failed to connect/authenticate Tor ControlPort. Retry $retries/$maxRetries Exception: $e');
        await Future.delayed(const Duration(seconds: 3));
      }
    }

    throw Exception('Unable to connect to Tor ControlPort after $maxRetries attempts');
  }

  /// Authenticate to Tor control port
  Future<void> _authenticate() async {
    if (_controlSocket == null) throw Exception('Control socket is not connected');

    final completer = Completer<void>();
    late StreamSubscription<String> sub;

    sub = _controlStream.listen((line) {
      //print('[Tor Control] $line');
      if (line.startsWith('250')) {
        completer.complete();
        sub.cancel();
      } else if (line.startsWith('515') || line.startsWith('5')) {
        completer.completeError('Authentication failed: $line');
        sub.cancel();
      }
    });

    _sendControlCommand('AUTHENTICATE "${controlPassword}"');
    return completer.future;
  }

  /// Send command to Tor control socket
  void _sendControlCommand(String command) {
    if (_controlSocket == null) throw Exception('Control socket is not connected');
    //print('[Tor Control] SEND: $command');
    _controlSocket!.write('$command\r\n');
  }

  /// Read onion address from Tor hidden service folder
  Future<String> getOnionAddress() async {
    final hostnameFile = File('$dataDir/hidden_service/hostname');
    if (!hostnameFile.existsSync()) {
      throw Exception('Hidden service not started or hostname file missing.');
    }
    return hostnameFile.readAsStringSync().trim();
  }

  /// Stop Tor process
  Future<void> stopTor() async {
    
    if (_controlSocket == null || _torProcess == null) return;

    final completer = Completer<void>();
    late StreamSubscription<String> sub;

    sub = _controlStream.listen((line) {
      if (line.startsWith("250")) {
        completer.complete();
        sub.cancel();
      } else if (line.startsWith("5") || line.startsWith("515")) {
        completer.completeError("Failed to shutdown Tor: $line");
        sub.cancel();
      }
    });

    try {
      _sendControlCommand("SIGNAL SHUTDOWN");
      await completer.future.timeout(const Duration(seconds: 10));
    } catch (e) {
      // timeout or error, continue to kill forcibly
    } finally {
      // avoid closing socket too early, add small delay to read responses
      await Future.delayed(const Duration(seconds: 1));
      await _controlSocket?.close();
      _controlSocket = null;
    }

    // Wait longer for graceful shutdown
    await Future.delayed(const Duration(seconds: 5));

    if (_torProcess != null) {
      try {
        // Try polite terminate first
        _torProcess!.kill(ProcessSignal.sigterm);
        await _torProcess!.exitCode.timeout(const Duration(seconds: 5));
      } catch (_) {
        // On timeout or error, try force kill
        try {
          _torProcess!.kill(ProcessSignal.sigkill);
          await _torProcess!.exitCode.timeout(const Duration(seconds: 5));
        } catch (_) {
          // ignore further errors
        }
      }
      _torProcess = null;
    }
  }

}
