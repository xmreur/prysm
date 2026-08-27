import 'dart:async';
import 'dart:io';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:prysm/services/call/call_capture_source.dart';
import 'package:prysm/services/call/call_pcm_playback.dart';
import 'package:prysm/services/call/call_session.dart';
import 'package:prysm/services/call/opus_codec.dart';
import 'package:prysm/services/call/pcm_gain_normalizer.dart';
import 'package:prysm/util/logging.dart';
import 'package:prysm/util/tor_service.dart';
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

  CallCaptureSource? _capture;
  bool _running = false;
  bool _muted = false;
  Future<void> _sendChain = Future.value();
  final PcmGainNormalizer _playbackGain = PcmGainNormalizer();

  @override
  bool get isRunning => _running;

  @override
  bool get isMuted => _muted;

  @override
  Future<bool> start() async {
    if (_running) return true;

    try {
      _codec ??= await OpusCodec.create(
        sampleRate: session.codec.sampleRate,
        channels: session.codec.channels,
        frameDurationMs: session.codec.frameDurationMs,
      );
      final codec = _codec;
      if (codec == null) {
        lastStartError = OpusCodec.lastLoadError ?? 'Opus codec unavailable';
        AudioEngine.lastStartError = lastStartError;
        return false;
      }

      if (!kIsWeb && Platform.isIOS) {
        await TorManager.setIosCallAudioActive(true);
        await _configureIosCallAudioSession();
        await AudioRecorder().ios?.manageAudioSession(false);
      }

      await _playback.start(
        sampleRate: codec.sampleRate,
        channels: codec.channels,
      );

      final capture = CallCaptureSource(
        sampleRate: codec.sampleRate,
        channels: codec.channels,
        frameSamples: codec.frameSamples,
        onFrame: _onCaptureFrame,
      );
      capture.setMuted(_muted);
      final started = await capture.start();
      if (!started) {
        lastStartError = CallCaptureSource.lastStartError;
        AudioEngine.lastStartError = lastStartError;
        await _playback.stop();
        return false;
      }
      _capture = capture;
      _running = true;
      lastStartError = null;
      AudioEngine.lastStartError = null;
      return true;
    } catch (e) {
      lastStartError = e.toString();
      AudioEngine.lastStartError = lastStartError;
      await stop();
      return false;
    }
  }

  void _onCaptureFrame(CallCaptureFrame frame) {
    if (!_running || _muted) return;
    final codec = _codec;
    if (codec == null) return;
    try {
      final opus = codec.encodeFrame(frame.pcm);
      _sendChain = chainAudioSend(
        _sendChain,
        () => session.encryptAudioFrame(opus),
        onSendFrame,
      );
    } catch (e) {
      if (kDebugMode) {
        Logging.error('encode failed: $e', 'AudioEngine');
      }
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
          Logging.error('decode failed: $e', 'AudioEngine');
        }
      }
    }());
  }

  Future<void> _configureIosCallAudioSession() async {
    final audioSession = await AudioSession.instance;
    await audioSession.configure(
      AudioSessionConfiguration(
        avAudioSessionCategory: AVAudioSessionCategory.playAndRecord,
        avAudioSessionCategoryOptions:
            AVAudioSessionCategoryOptions.defaultToSpeaker |
            AVAudioSessionCategoryOptions.allowBluetooth,
        avAudioSessionMode: AVAudioSessionMode.voiceChat,
      ),
    );
    await audioSession.setActive(true);
  }

  Future<void> _restoreIosCallAudioSession() async {
    await AudioRecorder().ios?.manageAudioSession(true);
    await TorManager.setIosCallAudioActive(false);
  }

  @override
  void setMuted(bool muted) {
    _muted = muted;
    _capture?.setMuted(muted);
  }

  @override
  Future<void> stop() async {
    _running = false;
    _sendChain = Future.value();
    await _capture?.stop();
    _capture = null;
    _playbackGain.reset();
    await _playback.stop();
    if (!kIsWeb && Platform.isIOS) {
      await _restoreIosCallAudioSession();
    }
    _codec?.dispose();
    _codec = null;
  }
}

CallAudio createCallAudio({
  required CallSession session,
  required CallAudioSendCallback onSendFrame,
}) => AudioEngine(session: session, onSendFrame: onSendFrame);
