import 'dart:async';
import 'dart:io';

import 'package:audio_session/audio_session.dart';
import 'package:audioplayers/audioplayers.dart' show AudioPlayer, AssetSource, ReleaseMode;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:prysm/services/call/call_manager.dart';
import 'package:prysm/util/logging.dart';

abstract class CallRingtonePort {
  Future<void> start();
  Future<void> stop();
  bool get isPlaying;
}

class CallRingtone implements CallRingtonePort {
  CallRingtone._();

  static CallRingtonePort? testOverride;
  static final CallRingtone _instance = CallRingtone._();

  static CallRingtonePort get instance => testOverride ?? _instance;

  static void resetState() {
    testOverride = null;
    unawaited(_instance.stop());
  }

  static const _assetPath = 'ringtones/prysm-ringtone.ogg';
  static const _bundlePath = 'assets/ringtones/prysm-ringtone.ogg';

  _CallRingtonePlayback? _playback;
  bool _playing = false;

  @override
  bool get isPlaying => _playing;

  @override
  Future<void> start() async {
    if (_playing) return;
    _playing = true;

    try {
      if (!kIsWeb && (Platform.isIOS || Platform.isMacOS)) {
        final session = await AudioSession.instance;
        await session.configure(
          AudioSessionConfiguration(
            avAudioSessionCategory: AVAudioSessionCategory.playback,
            avAudioSessionMode: AVAudioSessionMode.defaultMode,
          ),
        );
        await session.setActive(true);
      }

      _playback ??= _createPlayback();
      await _playback!.start();
    } catch (e) {
      _playing = false;
      Logging.error('Failed to start call ringtone: $e', 'CallRingtone');
    }
  }

  @override
  Future<void> stop() async {
    if (!_playing && _playback == null) return;
    _playing = false;

    try {
      await _playback?.stop();
      _playback = null;

      if (!kIsWeb && (Platform.isIOS || Platform.isMacOS)) {
        final session = await AudioSession.instance;
        await session.setActive(false);
      }
    } catch (e) {
      Logging.error('Failed to stop call ringtone: $e', 'CallRingtone');
    }
  }

  static Future<void> syncForState(
    CallSnapshot snapshot,
    CallSnapshot? previous,
  ) async {
    if (snapshot.state == CallState.incoming) {
      await instance.start();
    } else if (previous?.state == CallState.incoming) {
      await instance.stop();
    }
  }

  static _CallRingtonePlayback _createPlayback() {
    if (!kIsWeb && Platform.isLinux) {
      return _LinuxCallRingtonePlayback();
    }
    return _AudioplayersCallRingtonePlayback();
  }
}

abstract class _CallRingtonePlayback {
  Future<void> start();
  Future<void> stop();
}

class _AudioplayersCallRingtonePlayback implements _CallRingtonePlayback {
  AudioPlayer? _player;

  @override
  Future<void> start() async {
    _player ??= AudioPlayer();
    await _player!.setReleaseMode(ReleaseMode.loop);
    await _player!.play(AssetSource(CallRingtone._assetPath));
  }

  @override
  Future<void> stop() async {
    await _player?.stop();
    await _player?.dispose();
    _player = null;
  }
}

/// Linux playback via paplay/ffplay — avoids GStreamer plugin requirements.
class _LinuxCallRingtonePlayback implements _CallRingtonePlayback {
  Process? _process;
  String? _cachedPath;
  var _loopActive = false;

  @override
  Future<void> start() async {
    await stop();
    final path = await _resolveAssetPath();
    _loopActive = true;
    unawaited(_runLoop(path));
  }

  @override
  Future<void> stop() async {
    _loopActive = false;
    await _killProcess();
  }

  Future<String> _resolveAssetPath() async {
    if (_cachedPath != null) return _cachedPath!;
    final data = await rootBundle.load(CallRingtone._bundlePath);
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/prysm-ringtone.ogg');
    await file.writeAsBytes(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    );
    _cachedPath = file.path;
    return file.path;
  }

  Future<void> _runLoop(String path) async {
    try {
      final command = await _playbackCommand();
      if (command == 'ffplay') {
        _process = await Process.start(
          command,
          ['-nodisp', '-loop', '0', path],
        );
        await _process!.exitCode;
        return;
      }

      while (_loopActive) {
        _process = await Process.start(command, [path]);
        final code = await _process!.exitCode;
        if (!_loopActive) return;
        if (code != 0) {
          Logging.error(
            'Ringtone playback exited with code $code',
            'CallRingtone',
          );
          return;
        }
      }
    } catch (e) {
      if (_loopActive) {
        Logging.error('Linux ringtone playback failed: $e', 'CallRingtone');
      }
    }
  }

  Future<String> _playbackCommand() async {
    if (await _commandExists('ffplay')) return 'ffplay';
    for (final cmd in ['paplay', 'pw-play']) {
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
}
