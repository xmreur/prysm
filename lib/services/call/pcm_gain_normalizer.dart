import 'dart:math';
import 'dart:typed_data';

/// Smooths per-frame mic/playback level toward a target loudness.
class PcmGainNormalizer {
  PcmGainNormalizer({
    this.targetRms = 4500,
    this.maxPeak = 28000,
    this.minRms = 80,
    this.maxGain = 12,
    this.minGain = 0.15,
    this.smoothing = 0.18,
  });

  /// Desired RMS for a 20 ms speech frame (int16 scale).
  final double targetRms;

  /// Hard ceiling after gain is applied.
  final int maxPeak;

  /// Ignore frames quieter than this (silence / noise floor).
  final double minRms;

  final double maxGain;
  final double minGain;
  final double smoothing;

  double _gain = 1;

  void reset() => _gain = 1;

  Int16List normalize(Int16List pcm, {bool applyGain = true}) {
    if (pcm.isEmpty) return pcm;

    if (!applyGain) {
      _gain += (1.0 - _gain) * smoothing;
      return pcm;
    }

    var sumSq = 0.0;
    var peak = 0;
    for (final sample in pcm) {
      final abs = sample.abs();
      if (abs > peak) peak = abs;
      sumSq += sample * sample;
    }

    final rms = sqrt(sumSq / pcm.length);
    var desired = 1.0;
    if (rms > minRms) {
      desired = targetRms / rms;
    }
    if (peak > 0) {
      desired = min(desired, maxPeak / peak);
    }
    desired = desired.clamp(minGain, maxGain);

    _gain += (desired - _gain) * smoothing;

    final out = Int16List(pcm.length);
    final gain = _gain;
    for (var i = 0; i < pcm.length; i++) {
      final scaled = (pcm[i] * gain).round();
      out[i] = scaled.clamp(-32768, 32767);
    }
    return out;
  }

  Uint8List normalizeBytes(Uint8List pcmBytes, {bool applyGain = true}) {
    if (pcmBytes.isEmpty) return pcmBytes;
    final samples = Int16List.view(
      pcmBytes.buffer,
      pcmBytes.offsetInBytes,
      pcmBytes.lengthInBytes ~/ 2,
    );
    final normalized = normalize(samples, applyGain: applyGain);
    return normalized.buffer.asUint8List(
      normalized.offsetInBytes,
      normalized.lengthInBytes,
    );
  }
}
