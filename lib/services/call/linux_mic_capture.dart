import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:prysm/util/logging.dart';

/// Linux microphone capture via `pw-record` (PipeWire), matching the CLI path
/// that works reliably with Scarlett / native PipeWire devices.
class LinuxMicCapture {
  LinuxMicCapture._();

  static Process? _process;
  static StreamSubscription<List<int>>? _stdoutSub;
  static final _pcmController = StreamController<Uint8List>.broadcast();
  static final _levelController = StreamController<double>.broadcast();
  static bool _running = false;

  static Stream<Uint8List> get pcmStream => _pcmController.stream;

  static Stream<double> get inputLevel => _levelController.stream;

  static Future<Stream<Uint8List>> start({
    required int sampleRate,
    required int channels,
    String? deviceId,
  }) async {
    if (_running) {
      return pcmStream;
    }

    if (!await _commandExists('pw-record')) {
      throw StateError(
        'pw-record not found. Install PipeWire (pipewire-audio).',
      );
    }

    final args = <String>[
      '--format=s16',
      '--rate=$sampleRate',
      '--channels=$channels',
      if (deviceId != null && deviceId.isNotEmpty) '--target=$deviceId' else '-a',
      '-',
    ];

    Logging.debug('pw-record ${args.join(' ')}', 'LinuxMicCapture');
    

    _process = await Process.start('pw-record', args);
    _running = true;

    _stdoutSub = _process!.stdout.listen(
      (chunk) {
        if (chunk.isEmpty) return;
        final bytes = Uint8List.fromList(chunk);
        _pcmController.add(bytes);
        if (!_levelController.isClosed) {
          _levelController.add(_rmsS16(bytes));
        }
      },
      onError: (Object e) {
        if (!_pcmController.isClosed) {
          _pcmController.addError(e);
        }
      },
      onDone: () {
        if (_running && !_pcmController.isClosed) {
          _pcmController.addError(
            StateError('pw-record exited unexpectedly'),
          );
        }
      },
    );

    _process!.stderr.transform(utf8.decoder).listen((line) {
      if (line.trim().isNotEmpty) {
        Logging.debug(line.trim(), 'LinuxMicCapture');
      }
    });

    return pcmStream;
  }

  static Future<void> stop() async {
    _running = false;
    await _stdoutSub?.cancel();
    _stdoutSub = null;

    final proc = _process;
    _process = null;
    if (proc == null) return;

    proc.kill();
    try {
      await proc.exitCode.timeout(
        const Duration(seconds: 1),
        onTimeout: () {
          proc.kill(ProcessSignal.sigkill);
          return -1;
        },
      );
    } catch (_) {}
  }

  static double _rmsS16(Uint8List bytes) {
    if (bytes.length < 2) return 0;
    final view = ByteData.sublistView(bytes);
    final count = bytes.length ~/ 2;
    var sum = 0.0;
    for (var i = 0; i < count; i++) {
      final v = view.getInt16(i * 2, Endian.little).toDouble();
      sum += v * v;
    }
    return min(1.0, sqrt(sum / count) / 32768.0);
  }

  static Future<bool> _commandExists(String command) async {
    final result = await Process.run('which', [command]);
    return result.exitCode == 0;
  }
}
