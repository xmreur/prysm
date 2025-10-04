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
    this.controlPassword = 'my_password', // Or generate securely and configure in torrc
  });

  /// Launch Tor process with control port enabled and set up control connection
  Future<void> startTor() async {
    final torrcPath = await _writeTorrc();

    _torProcess = await Process.start(
      torPath,
      ['-f', torrcPath],
      mode: ProcessStartMode.detachedWithStdio,
    );

    _torProcess!.stdout.transform(utf8.decoder).listen((data) {
      stdoutController.add(data);
      print('[Tor] stdout: $data');
    });

    _torProcess!.stderr.transform(utf8.decoder).listen((data) {
      stderrController.add(data);
      print('[Tor] stderr: $data');
    });

    // Connect to control port (wait for readiness and authenticate)
    await _connectControlPort();

    print('Tor process started and authenticated.');
  }

  /// Write torrc config file with ControlPort, DataDirectory, and HashedControlPassword
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

  /// Spawn subprocess to hash the control password securely
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
        print('Connected to Tor ControlPort on $controlPort');

        // Setup broadcast stream for multiple listeners
        _controlStream = _controlSocket!
            .cast<List<int>>()
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .asBroadcastStream();

        // Listen for socket closure
        _controlSocket!.done.then((_) {
          print('Tor ControlPort socket closed');
          _controlSocket = null;
        });

        // Authenticate immediately after connection
        await _authenticate();

        // Success, exit loop
        return;
      } catch (e) {
        retries++;
        print('Failed to connect/authenticate Tor ControlPort. Retry $retries/$maxRetries Exception: $e');
        await Future.delayed(const Duration(seconds: 3));
      }
    }

    throw Exception('Unable to connect to Tor ControlPort after $maxRetries attempts');
  }

  /// Authenticate to Tor control port using password
  Future<void> _authenticate() async {
    if (_controlSocket == null) throw Exception('Control socket is not connected');

    final completer = Completer<void>();
    late StreamSubscription<String> sub;

    sub = _controlStream.listen((line) {
      print('[Tor Control] $line');
      if (line.startsWith('250')) {
        completer.complete();
        sub.cancel();
      } else if (line.startsWith('515') || line.startsWith('5')) {
        completer.completeError('Authentication failed with response: $line');
        sub.cancel();
      }
    });

    _sendControlCommand('AUTHENTICATE "${controlPassword}"');

    return completer.future;
  }

  /// Send raw command to control socket
  void _sendControlCommand(String command) {
    if (_controlSocket == null) throw Exception('Control socket is not connected');
    print('[Tor Control] SEND: $command');
    _controlSocket!.write('$command\r\n');
  }

  /// Create a new hidden service and return onion address
  Future<String> createHiddenService(int virtualPort, int targetPort) async {
    if (_controlSocket == null) throw Exception('Control socket is not connected');

    final completer = Completer<String>();
    late StreamSubscription<String> sub;

    sub = _controlStream.listen((line) {
      print('[Tor Control] $line');
      if (line.startsWith('250-ServiceID=')) {
        final onion = line.split('=')[1].trim();
        completer.complete('$onion.onion');
        sub.cancel();
      } else if (line.startsWith('550')) {
        completer.completeError('Failed to create hidden service: $line');
        sub.cancel();
      }
    });

    _sendControlCommand('ADD_ONION NEW:ED25519-V3 Port=$virtualPort,127.0.0.1:$targetPort');

    return completer.future;
  }

  /// Properly stop Tor process
  Future<void> stopTor() async {
    try {
      _sendControlCommand('SIGNAL SHUTDOWN');
      await _controlSocket?.close();
    } catch (_) {
      // ignore errors
    }
    _torProcess?.kill();
  }
}
