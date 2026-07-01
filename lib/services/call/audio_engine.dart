import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:prysm/services/call/call_pcm_playback.dart';
import 'package:prysm/services/call/call_session.dart';
import 'package:prysm/services/call/linux_audio_settings.dart';
import 'package:prysm/services/call/linux_mic_capture.dart';
import 'package:prysm/services/call/opus_codec.dart';
import 'package:prysm/services/call/pcm_capture_processor.dart';
import 'package:prysm/services/call/pcm_gain_normalizer.dart';
import 'package:record/record.dart';

typedef CallAudioSendCallback = void Function(Uint8List encryptedFrame);

/// Serializes async encrypt+send so capture frames leave in order.
@visibleForTesting
Future<void> chainAudioSend(
  Future<void> chain,
  Future<Uint8List> Function() encrypt,
  CallAudioSendCallback send,
) => chain.then((_) async => send(await encrypt()));

abstract class CallAudio {
  Future<bool> start();
  Future<void> stop();
  void handleIncoming(Uint8List encryptedFrame);
  void setMuted(bool muted);
  bool get isRunning;
  bool get isMuted;
}

class AudioEngine implements CallAudio {
  AudioEngine({
    required this.session,
    required this.onSendFrame,
    OpusCodec? codec,
    CallPcmPlayback? playback,
  }) : _codec = codec,
       _playback = playback ?? createCallPcmPlayback();

  static String? lastStartError;

  final CallSession session;
  final CallAudioSendCallback onSendFrame;
  OpusCodec? _codec;
  final CallPcmPlayback _playback;

  final AudioRecorder _recorder = AudioRecorder();
  StreamSubscription<Uint8List>? _captureSub;
  final List<int> _pcmBuffer = [];
  bool _running = false;
  bool _muted = false;
  bool _linuxCaptureActive = false;
  Future<void> _sendChain = Future.value();
  final PcmGainNormalizer _captureGain = PcmGainNormalizer();
  final PcmGainNormalizer _playbackGain = PcmGainNormalizer();
  final PcmCaptureProcessor _captureProcessor = PcmCaptureProcessor();

  @override
  bool get isRunning => _running;

  @override
  bool get isMuted => _muted;

  @override
  Future<bool> start() async {
    if (_running) return true;

    if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
      final status = await Permission.microphone.request();
      if (!status.isGranted) {
        AudioEngine.lastStartError = 'Microphone permission denied';
        return false;
      }
    }

    try {
      _codec ??= await OpusCodec.create(
        sampleRate: session.codec.sampleRate,
        channels: session.codec.channels,
        frameDurationMs: session.codec.frameDurationMs,
      );
      final codec = _codec;
      if (codec == null) {
        AudioEngine.lastStartError =
            OpusCodec.lastLoadError ?? 'Opus codec unavailable';
        return false;
      }

      await _playback.start(
        sampleRate: codec.sampleRate,
        channels: codec.channels,
      );

      final Stream<Uint8List> stream;
      if (!kIsWeb && Platform.isLinux) {
        final deviceId = await LinuxAudioSettings.getSelectedDeviceId();
        stream = await LinuxMicCapture.start(
          sampleRate: codec.sampleRate,
          channels: codec.channels,
          deviceId: deviceId,
        );
        _linuxCaptureActive = true;
      } else {
        stream = await _recorder.startStream(_captureConfig());
      }

      _running = true;
      final bytesPerFrame = codec.frameSamples * codec.channels * 2;
      _captureSub = stream.listen(
        (chunk) {
          if (!_running || _muted || chunk.isEmpty) return;
          _pcmBuffer.addAll(chunk);
          while (_pcmBuffer.length >= bytesPerFrame) {
            final frameBytes = Uint8List.fromList(
              _pcmBuffer.sublist(0, bytesPerFrame),
            );
            _pcmBuffer.removeRange(0, bytesPerFrame);
            final pcm = Int16List.view(
              frameBytes.buffer,
              frameBytes.offsetInBytes,
              frameBytes.lengthInBytes ~/ 2,
            );
            try {
              final cleaned = _captureProcessor.process(pcm);
              final normalized = _captureGain.normalize(
                cleaned,
                applyGain: _captureProcessor.gateOpen,
              );
              final opus = codec.encodeFrame(normalized);
              _sendChain = chainAudioSend(
                _sendChain,
                () => session.encryptAudioFrame(opus),
                onSendFrame,
              );
            } catch (e) {
              if (kDebugMode) {
                debugPrint('AudioEngine: encode failed: $e');
              }
            }
          }
        },
        onError: (Object e) {
          AudioEngine.lastStartError = 'Microphone stream error: $e';
          if (kDebugMode) {
            debugPrint('AudioEngine: capture stream error: $e');
          }
        },
      );

      AudioEngine.lastStartError = null;
      return true;
    } on PlatformException catch (e) {
      AudioEngine.lastStartError =
          e.message ?? 'Linux microphone capture failed';
      await stop();
      return false;
    } catch (e) {
      AudioEngine.lastStartError = e.toString();
      await stop();
      return false;
    }
  }

  @override
  void handleIncoming(Uint8List encryptedFrame) {
    if (!_running) return;
    final codec = _codec;
    if (codec == null) return;

    unawaited(() async {
      final opus = await session.decryptAudioFrame(encryptedFrame);
      if (opus == null || !_running) return;
      try {
        final pcm = codec.decodeFrame(opus);
        final normalized = _playbackGain.normalize(pcm);
        final bytes = normalized.buffer.asUint8List(
          normalized.offsetInBytes,
          normalized.lengthInBytes,
        );
        _playback.playPcm(bytes);
      } catch (e) {
        if (kDebugMode) {
          debugPrint('AudioEngine: decode failed: $e');
        }
      }
    }());
  }

  RecordConfig _captureConfig() {
    return const RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: 16000,
      numChannels: 1,
      echoCancel: true,
      noiseSuppress: true,
    );
  }

  @override
  void setMuted(bool muted) {
    _muted = muted;
  }

  @override
  Future<void> stop() async {
    _running = false;
    _sendChain = Future.value();
    await _captureSub?.cancel();
    _captureSub = null;
    _pcmBuffer.clear();
    if (await _recorder.isRecording()) {
      await _recorder.stop();
    }
    if (_linuxCaptureActive) {
      await LinuxMicCapture.stop();
      _linuxCaptureActive = false;
    }
    _captureGain.reset();
    _playbackGain.reset();
    _captureProcessor.reset();
    await _playback.stop();
    _codec?.dispose();
    _codec = null;
  }
}

CallAudio createCallAudio({
  required CallSession session,
  required CallAudioSendCallback onSendFrame,
}) => AudioEngine(session: session, onSendFrame: onSendFrame);
