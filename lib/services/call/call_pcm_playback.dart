import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';
import 'package:just_audio/just_audio.dart';
import 'package:prysm/services/call/pcm_jitter_buffer.dart';

/// Plays live PCM16 audio received during a call.
abstract class CallPcmPlayback {
  Future<void> start({required int sampleRate, required int channels});

  void playPcm(Uint8List pcm);

  Future<void> stop();
}

CallPcmPlayback createCallPcmPlayback() {
  if (!kIsWeb && Platform.isLinux) {
    return _LinuxPipePcmPlayback();
  }
  if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
    return _FlutterPcmPlayback();
  }
  return _JustAudioPcmPlayback();
}

/// Low-latency PCM playback for Android/iOS using flutter_pcm_sound.
class _FlutterPcmPlayback implements CallPcmPlayback {
  PcmJitterBuffer? _buffer;
  bool _running = false;

  @override
  Future<void> start({required int sampleRate, required int channels}) async {
    _buffer = PcmJitterBuffer(
      sampleRate: sampleRate,
      channels: channels,
      minStartMs: 60,
      chunkMs: 40,
      maxLatencyMs: 180,
    );
    await FlutterPcmSound.setLogLevel(LogLevel.error);
    await FlutterPcmSound.setup(
      sampleRate: sampleRate,
      channelCount: channels,
      iosAudioCategory: IosAudioCategory.playAndRecord,
    );
    await FlutterPcmSound.setFeedThreshold(sampleRate ~/ 4);
    FlutterPcmSound.setFeedCallback((_) => _drain());
    FlutterPcmSound.start();
    _running = true;
  }

  @override
  void playPcm(Uint8List pcm) {
    if (!_running) return;
    _buffer?.push(pcm);
    _drain();
  }

  void _drain() {
    if (!_running) return;
    final buffer = _buffer;
    if (buffer == null) return;
    while (true) {
      final chunk = buffer.take();
      if (chunk == null) break;
      unawaited(
        FlutterPcmSound.feed(
          PcmArrayInt16(bytes: ByteData.sublistView(chunk)),
        ).catchError((_) {}),
      );
    }
  }

  @override
  Future<void> stop() async {
    _running = false;
    _buffer?.reset();
    _buffer = null;
    FlutterPcmSound.setFeedCallback(null);
    try {
      await FlutterPcmSound.release();
    } catch (_) {}
  }
}

class _JustAudioPcmPlayback implements CallPcmPlayback {
  AudioPlayer? _player;
  _LivePcmSource? _source;
  PcmJitterBuffer? _buffer;
  bool _playbackStarted = false;

  @override
  Future<void> start({required int sampleRate, required int channels}) async {
    _playbackStarted = false;
    _buffer = PcmJitterBuffer(sampleRate: sampleRate, channels: channels);
    _player = AudioPlayer();
    _source = _LivePcmSource(sampleRate: sampleRate, channels: channels);
    await _player!.setAudioSource(_source!);
  }

  @override
  void playPcm(Uint8List pcm) {
    final buffer = _buffer;
    if (buffer == null) return;
    buffer.push(pcm);
    while (true) {
      final chunk = buffer.take();
      if (chunk == null) break;
      _source?.addPcm(chunk);
    }
    if (_playbackStarted) return;
    final player = _player;
    if (player == null) return;
    _playbackStarted = true;
    unawaited(player.play());
  }

  @override
  Future<void> stop() async {
    _buffer?.reset();
    _buffer = null;
    await _source?.close();
    _source = null;
    final player = _player;
    _player = null;
    if (player != null) {
      try {
        await player.stop();
      } catch (_) {}
      try {
        await player.dispose();
      } catch (_) {}
    }
  }
}

/// Streams raw s16le PCM to paplay/pw-play on Linux.
class _LinuxPipePcmPlayback implements CallPcmPlayback {
  Process? _process;
  IOSink? _stdin;
  PcmJitterBuffer? _buffer;

  @override
  Future<void> start({required int sampleRate, required int channels}) async {
    final command = await _playbackCommand();
    final args = _buildArgs(command, sampleRate, channels);
    _process = await Process.start(command, args);
    _stdin = _process!.stdin;
    _buffer = PcmJitterBuffer(
      sampleRate: sampleRate,
      channels: channels,
      minStartMs: 60,
      chunkMs: 40,
      maxLatencyMs: 180,
    );
  }

  @override
  void playPcm(Uint8List pcm) {
    final buffer = _buffer;
    final sink = _stdin;
    if (buffer == null || sink == null) return;
    buffer.push(pcm);
    while (true) {
      final chunk = buffer.take();
      if (chunk == null) break;
      try {
        sink.add(chunk);
      } catch (_) {
        return;
      }
    }
    try {
      sink.flush();
    } catch (_) {}
  }

  @override
  Future<void> stop() async {
    _buffer?.reset();
    _buffer = null;
    final sink = _stdin;
    _stdin = null;
    if (sink != null) {
      try {
        await sink.close();
      } catch (_) {}
    }
    final proc = _process;
    _process = null;
    if (proc == null) return;
    try {
      proc.kill();
      await proc.exitCode.timeout(
        const Duration(seconds: 1),
        onTimeout: () {
          proc.kill(ProcessSignal.sigkill);
          return -1;
        },
      );
    } catch (_) {}
  }

  Future<String> _playbackCommand() async {
    for (final cmd in ['pw-play', 'paplay']) {
      if (await _commandExists(cmd)) return cmd;
    }
    throw StateError(
      'No raw PCM playback tool found. Install PulseAudio/PipeWire (paplay or pw-play).',
    );
  }

  Future<bool> _commandExists(String command) async {
    final result = await Process.run('which', [command]);
    return result.exitCode == 0;
  }

  List<String> _buildArgs(String command, int sampleRate, int channels) {
    switch (command) {
      case 'pw-play':
        return [
          '--raw',
          '--format=s16',
          '--rate=$sampleRate',
          '--channels=$channels',
          '-',
        ];
      case 'paplay':
      default:
        return [
          '--raw',
          '--format=s16le',
          '--rate=$sampleRate',
          '--channels=$channels',
          '--latency-msec=25',
        ];
    }
  }
}

// ignore: experimental_member_use
class _LivePcmSource extends StreamAudioSource {
  _LivePcmSource({required this.sampleRate, required this.channels});

  final int sampleRate;
  final int channels;
  final _controller = StreamController<List<int>>.broadcast();
  bool _closed = false;
  int _bytesWritten = 0;

  void addPcm(Uint8List pcm) {
    if (_closed) return;
    _bytesWritten += pcm.length;
    _controller.add(pcm);
  }

  Future<void> close() async {
    _closed = true;
    await _controller.close();
  }

  @override
  // ignore: experimental_member_use
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    final header = _wavHeader(
      dataSize: _bytesWritten > 0 ? _bytesWritten : 0x7fffffff,
    );
    final stream = Stream<List<int>>.multi((controller) {
      controller.add(header);
      final sub = _controller.stream.listen(
        controller.add,
        onError: controller.addError,
        onDone: controller.close,
        cancelOnError: false,
      );
      controller.onCancel = () => sub.cancel();
    });
    // ignore: experimental_member_use
    return StreamAudioResponse(
      rangeRequestsSupported: false,
      sourceLength: null,
      contentLength: null,
      offset: null,
      contentType: 'audio/wav',
      stream: stream,
    );
  }

  Uint8List _wavHeader({required int dataSize}) {
    final byteRate = sampleRate * channels * 2;
    final blockAlign = channels * 2;
    final header = ByteData(44);
    header.setUint8(0, 0x52);
    header.setUint8(1, 0x49);
    header.setUint8(2, 0x46);
    header.setUint8(3, 0x46);
    header.setUint32(4, 36 + dataSize, Endian.little);
    header.setUint8(8, 0x57);
    header.setUint8(9, 0x41);
    header.setUint8(10, 0x56);
    header.setUint8(11, 0x45);
    header.setUint8(12, 0x66);
    header.setUint8(13, 0x6d);
    header.setUint8(14, 0x74);
    header.setUint8(15, 0x20);
    header.setUint32(16, 16, Endian.little);
    header.setUint16(20, 1, Endian.little);
    header.setUint16(22, channels, Endian.little);
    header.setUint32(24, sampleRate, Endian.little);
    header.setUint32(28, byteRate, Endian.little);
    header.setUint16(32, blockAlign, Endian.little);
    header.setUint16(34, 16, Endian.little);
    header.setUint8(36, 0x64);
    header.setUint8(37, 0x61);
    header.setUint8(38, 0x74);
    header.setUint8(39, 0x61);
    header.setUint32(40, dataSize, Endian.little);
    return header.buffer.asUint8List();
  }
}
