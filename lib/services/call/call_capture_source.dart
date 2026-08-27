import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:prysm/services/call/linux_audio_settings.dart';
import 'package:prysm/services/call/linux_mic_capture.dart';
import 'package:prysm/services/call/pcm_capture_processor.dart';
import 'package:prysm/services/call/pcm_gain_normalizer.dart';
import 'package:prysm/util/logging.dart';
import 'package:record/record.dart';

class CallCaptureFrame {
  const CallCaptureFrame({required this.pcm, required this.gateOpen});

  final Int16List pcm;
  final bool gateOpen;
}

typedef CallCaptureCallback = void Function(CallCaptureFrame frame);

/// Platform mic capture shared by 1:1 and group call audio engines.
class CallCaptureSource {
  CallCaptureSource({
    required this.sampleRate,
    required this.channels,
    required this.frameSamples,
    required this.onFrame,
  });

  final int sampleRate;
  final int channels;
  final int frameSamples;
  final CallCaptureCallback onFrame;

  static String? lastStartError;

  final AudioRecorder _recorder = AudioRecorder();
  StreamSubscription<Uint8List>? _captureSub;
  final List<int> _pcmBuffer = [];
  final PcmGainNormalizer _captureGain = PcmGainNormalizer();
  final PcmCaptureProcessor _captureProcessor = PcmCaptureProcessor();
  bool _running = false;
  bool _muted = false;
  bool _linuxCaptureActive = false;

  bool get isRunning => _running;

  void setMuted(bool muted) {
    _muted = muted;
  }

  Future<bool> start() async {
    if (_running) return true;

    if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
      final status = await Permission.microphone.request();
      if (!status.isGranted) {
        lastStartError = 'Microphone permission denied';
        return false;
      }
    }

    try {
      final Stream<Uint8List> stream;
      if (!kIsWeb && Platform.isLinux) {
        final deviceId = await LinuxAudioSettings.getSelectedDeviceId();
        stream = await LinuxMicCapture.start(
          sampleRate: sampleRate,
          channels: channels,
          deviceId: deviceId,
        );
        _linuxCaptureActive = true;
      } else {
        stream = await _recorder.startStream(_captureConfig());
      }

      _running = true;
      final bytesPerFrame = frameSamples * channels * 2;
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
              onFrame(
                CallCaptureFrame(
                  pcm: normalized,
                  gateOpen: _captureProcessor.gateOpen,
                ),
              );
            } catch (e) {
              if (kDebugMode) {
                Logging.error('capture process failed: $e', 'CallCaptureSource');
              }
            }
          }
        },
        onError: (Object e) {
          lastStartError = 'Microphone stream error: $e';
          if (kDebugMode) {
            Logging.error('capture stream error: $e', 'CallCaptureSource');
          }
        },
      );

      lastStartError = null;
      return true;
    } on PlatformException catch (e) {
      lastStartError = e.message ?? 'Linux microphone capture failed';
      await stop();
      return false;
    } catch (e) {
      lastStartError = e.toString();
      await stop();
      return false;
    }
  }

  RecordConfig _captureConfig() {
    return RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: sampleRate,
      numChannels: channels,
      echoCancel: true,
      noiseSuppress: true,
    );
  }

  Future<void> stop() async {
    _running = false;
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
    _captureProcessor.reset();
  }
}
