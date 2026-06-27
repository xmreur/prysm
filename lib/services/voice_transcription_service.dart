import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:prysm/database/voice_transcripts_db.dart';
import 'package:prysm/util/stt_model_manager.dart';
import 'package:prysm/util/waveform_extractor.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart';

class VoiceTranscriptionService {
  VoiceTranscriptionService._();
  static final VoiceTranscriptionService instance = VoiceTranscriptionService._();

  static const maxDurationMs = 5 * 60 * 1000;

  final _inFlight = <String, Future<String?>>{};

  bool get isSupported => !kIsWeb;

  Future<String?> getCachedTranscript(String messageId) {
    return VoiceTranscriptsDb.get(messageId);
  }

  Future<String?> transcribe({
    required String messageId,
    required String wavPath,
    void Function(double progress)? onModelProgress,
  }) async {
    if (!isSupported) return null;

    final cached = await VoiceTranscriptsDb.get(messageId);
    if (cached != null) return cached;

    final pending = _inFlight[messageId];
    if (pending != null) return pending;

    final future = _transcribeUncached(
      messageId: messageId,
      wavPath: wavPath,
      onModelProgress: onModelProgress,
    );
    _inFlight[messageId] = future;
    try {
      return await future;
    } finally {
      _inFlight.remove(messageId);
    }
  }

  Future<String?> _transcribeUncached({
    required String messageId,
    required String wavPath,
    void Function(double progress)? onModelProgress,
  }) async {
    final file = File(wavPath);
    if (!await file.exists()) return null;

    final bytes = await file.readAsBytes();
    final durationMs = WaveformExtractor.estimateDurationMs(bytes);
    if (durationMs > maxDurationMs) {
      throw VoiceTranscriptionException(
        'Voice message is too long to transcribe (max 5 minutes)',
      );
    }

    final modelDir = await SttModelManager.instance.ensureModelReady(
      onProgress: onModelProgress,
    );

    final text = await Isolate.run(
      () => _transcribeInIsolate(
        _TranscribeIsolateArgs(modelDir: modelDir, wavPath: wavPath),
      ),
    );

    if (text != null && text.isNotEmpty) {
      await VoiceTranscriptsDb.put(messageId, text);
    }
    return text;
  }
}

class VoiceTranscriptionException implements Exception {
  VoiceTranscriptionException(this.message);
  final String message;

  @override
  String toString() => message;
}

class _TranscribeIsolateArgs {
  const _TranscribeIsolateArgs({
    required this.modelDir,
    required this.wavPath,
  });

  final String modelDir;
  final String wavPath;
}

String? _transcribeInIsolate(_TranscribeIsolateArgs args) {
  initBindings();

  final encoder = p.join(args.modelDir, SttModelManager.encoderFile);
  final decoder = p.join(args.modelDir, SttModelManager.decoderFile);
  final tokens = p.join(args.modelDir, SttModelManager.tokensFile);

  final config = OfflineRecognizerConfig(
    model: OfflineModelConfig(
      whisper: OfflineWhisperModelConfig(
        encoder: encoder,
        decoder: decoder,
      ),
      tokens: tokens,
      modelType: 'whisper',
      numThreads: 2,
      debug: false,
      provider: 'cpu',
    ),
    decodingMethod: 'greedy_search',
  );

  final recognizer = OfflineRecognizer(config);
  try {
    final wave = readWave(args.wavPath);
    final stream = recognizer.createStream();
    try {
      stream.acceptWaveform(
        samples: wave.samples,
        sampleRate: wave.sampleRate,
      );
      recognizer.decode(stream);
      final text = recognizer.getResult(stream).text.trim();
      return text.isEmpty ? null : text;
    } finally {
      stream.free();
    }
  } finally {
    recognizer.free();
  }
}
