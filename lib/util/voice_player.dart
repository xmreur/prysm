import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

/// Playback backend for voice messages.
///
/// Linux desktop uses PipeWire/PulseAudio CLI tools ([paplay], [pw-play]) —
/// no GStreamer plugins required at runtime. Mobile/desktop otherwise use
/// [audioplayers].
abstract class VoicePlayer {
  Stream<bool> get playingStream;
  Stream<Duration> get positionStream;
  Stream<Duration> get durationStream;
  Stream<void> get completeStream;

  Future<void> playFile(String path, {Duration start = Duration.zero});
  Future<void> pause();
  Future<void> resume();
  Future<void> stop();
  Future<void> seek(Duration position);
  void setExpectedDuration(Duration duration) {}
  Future<void> dispose();
}

VoicePlayer createVoicePlayer() {
  if (!kIsWeb && Platform.isLinux) {
    return _LinuxVoicePlayer();
  }
  return _AudioplayersVoicePlayer();
}

class _AudioplayersVoicePlayer implements VoicePlayer {
  final AudioPlayer _player = AudioPlayer();

  @override
  Stream<bool> get playingStream =>
      _player.onPlayerStateChanged.map((s) => s == PlayerState.playing);

  @override
  Stream<Duration> get positionStream => _player.onPositionChanged;

  @override
  Stream<Duration> get durationStream => _player.onDurationChanged;

  @override
  Stream<void> get completeStream => _player.onPlayerComplete;

  @override
  Future<void> playFile(String path, {Duration start = Duration.zero}) async {
    await _player.play(DeviceFileSource(path, mimeType: 'audio/wav'));
    if (start > Duration.zero) {
      await _player.seek(start);
    }
  }

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> resume() => _player.resume();

  @override
  Future<void> stop() => _player.stop();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  void setExpectedDuration(Duration duration) {}

  @override
  Future<void> dispose() => _player.dispose();
}

/// Linux playback via paplay/ffplay — avoids GStreamer plugin requirements.
class _LinuxVoicePlayer implements VoicePlayer {
  Process? _process;
  String? _path;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  var _isPlaying = false;
  var _isPaused = false;
  Timer? _positionTimer;

  final _playingController = StreamController<bool>.broadcast();
  final _positionController = StreamController<Duration>.broadcast();
  final _durationController = StreamController<Duration>.broadcast();
  final _completeController = StreamController<void>.broadcast();

  @override
  Stream<bool> get playingStream => _playingController.stream;

  @override
  Stream<Duration> get positionStream => _positionController.stream;

  @override
  Stream<Duration> get durationStream => _durationController.stream;

  @override
  Stream<void> get completeStream => _completeController.stream;

  Future<String> _playbackCommand(Duration start) async {
    if (start == Duration.zero) {
      for (final cmd in ['paplay', 'pw-play', 'aplay']) {
        if (await _commandExists(cmd)) return cmd;
      }
    }
    if (await _commandExists('ffplay')) {
      return 'ffplay';
    }
    for (final cmd in ['paplay', 'pw-play', 'aplay']) {
      if (await _commandExists(cmd)) return cmd;
    }
    throw StateError(
      'No audio playback tool found. Install PulseAudio/PipeWire (paplay) '
      'or ffmpeg (ffplay).',
    );
  }

  Future<bool> _commandExists(String command) async {
    final result = await Process.run('which', [command]);
    return result.exitCode == 0;
  }

  List<String> _buildArgs(String command, String path, Duration start) {
    switch (command) {
      case 'ffplay':
        return [
          '-nodisp',
          '-autoexit',
          if (start > Duration.zero) ...[
            '-ss',
            '${start.inMilliseconds / 1000.0}',
          ],
          path,
        ];
      case 'paplay':
      case 'pw-play':
      case 'aplay':
        return [path];
      default:
        return [path];
    }
  }

  void _startPositionTimer() {
    _positionTimer?.cancel();
    _positionTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (!_isPlaying || _isPaused) return;
      _position += const Duration(milliseconds: 100);
      if (_duration > Duration.zero && _position >= _duration) {
        _position = _duration;
      }
      _positionController.add(_position);
    });
  }

  Future<void> _killProcess() async {
    final proc = _process;
    _process = null;
    if (proc == null) return;
    try {
      proc.kill();
      await proc.exitCode.timeout(const Duration(seconds: 2), onTimeout: () {
        proc.kill(ProcessSignal.sigkill);
        return -1;
      });
    } catch (_) {}
  }

  @override
  Future<void> playFile(String path, {Duration start = Duration.zero}) async {
    await stop();
    _path = path;
    _position = start;
    _isPaused = false;

    final command = await _playbackCommand(start);
    _process = await Process.start(
      command,
      _buildArgs(command, path, start),
    );

    _isPlaying = true;
    _playingController.add(true);
    _startPositionTimer();

    final proc = _process!;
    proc.exitCode.then((code) {
      if (_process != proc) return;
      _process = null;
      _isPlaying = false;
      _isPaused = false;
      _positionTimer?.cancel();
      _playingController.add(false);
      if (code == 0) {
        _completeController.add(null);
      }
    });
  }

  @override
  Future<void> pause() async {
    if (!_isPlaying || _isPaused || _process == null) return;
    _process!.kill(ProcessSignal.sigstop);
    _isPaused = true;
    _playingController.add(false);
  }

  @override
  Future<void> resume() async {
    if (!_isPlaying || !_isPaused || _process == null) return;
    _process!.kill(ProcessSignal.sigcont);
    _isPaused = false;
    _playingController.add(true);
  }

  @override
  Future<void> stop() async {
    _positionTimer?.cancel();
    await _killProcess();
    _isPlaying = false;
    _isPaused = false;
    _playingController.add(false);
  }

  @override
  Future<void> seek(Duration position) async {
    final clamped = position.isNegative ? Duration.zero : position;
    _position = clamped;
    _positionController.add(_position);

    if (!_isPlaying || _path == null) return;

    final wasPaused = _isPaused;
    await _killProcess();
    _isPlaying = false;
    _isPaused = false;

    await playFile(_path!, start: clamped);
    if (wasPaused) {
      await pause();
    }
  }

  @override
  void setExpectedDuration(Duration duration) {
    _duration = duration;
    _durationController.add(duration);
  }

  @override
  Future<void> dispose() async {
    await stop();
    await _playingController.close();
    await _positionController.close();
    await _durationController.close();
    await _completeController.close();
  }
}
