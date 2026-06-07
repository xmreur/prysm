import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

/// Extracts normalized waveform peaks from Prysm voice WAV payloads.
/// Recorder settings: 16 kHz, mono, 16-bit PCM ([message_composer.dart]).
class WaveformExtractor {
  WaveformExtractor._();

  static const int defaultBinCount = 48;

  /// Normalized peaks in [0, 1], length [binCount].
  static List<double> extractPeaks(
    Uint8List wavBytes, {
    int binCount = defaultBinCount,
  }) {
    final info = _parseWav(wavBytes);
    if (info == null || info.bitsPerSample != 16) {
      return List.filled(binCount, 0.15);
    }

    final pcm = wavBytes.sublist(
      info.dataOffset,
      min(wavBytes.length, info.dataOffset + info.dataSize),
    );
    final sampleCount = pcm.length ~/ 2;
    if (sampleCount == 0) {
      return List.filled(binCount, 0.15);
    }

    final bins = List<double>.filled(binCount, 0);
    final samplesPerBin = max(1, sampleCount ~/ binCount);

    var globalMax = 0;
    for (var bin = 0; bin < binCount; bin++) {
      final start = bin * samplesPerBin;
      final end = min(sampleCount, start + samplesPerBin);
      var peak = 0;
      for (var i = start; i < end; i++) {
        final offset = i * 2;
        if (offset + 1 >= pcm.length) break;
        final sample = pcm[offset] | (pcm[offset + 1] << 8);
        final signed = sample > 32767 ? sample - 65536 : sample;
        final abs = signed.abs();
        if (abs > peak) peak = abs;
      }
      bins[bin] = peak.toDouble();
      if (peak > globalMax) globalMax = peak;
    }

    if (globalMax == 0) {
      return List.filled(binCount, 0.15);
    }

    return bins.map((v) => (v / globalMax).clamp(0.05, 1.0)).toList();
  }

  static int estimateDurationMs(Uint8List wavBytes) {
    final info = _parseWav(wavBytes);
    if (info == null || info.sampleRate <= 0 || info.numChannels <= 0) {
      return 0;
    }
    final bytesPerSample = info.bitsPerSample ~/ 8;
    final bytesPerSecond =
        info.sampleRate * info.numChannels * bytesPerSample;
    if (bytesPerSecond <= 0) return 0;
    return (info.dataSize / bytesPerSecond * 1000).round();
  }

  static _WavInfo? _parseWav(Uint8List bytes) {
    if (bytes.length < 12) return null;
    if (String.fromCharCodes(bytes.sublist(0, 4)) != 'RIFF') return null;
    if (String.fromCharCodes(bytes.sublist(8, 12)) != 'WAVE') return null;

    var offset = 12;
    var sampleRate = 16000;
    var numChannels = 1;
    var bitsPerSample = 16;
    int? dataOffset;
    var dataSize = 0;

    while (offset + 8 <= bytes.length) {
      final chunkId = String.fromCharCodes(bytes.sublist(offset, offset + 4));
      final chunkSize = _le32(bytes, offset + 4);
      offset += 8;

      if (offset + chunkSize > bytes.length) break;

      if (chunkId == 'fmt ' && chunkSize >= 16) {
        numChannels = _le16(bytes, offset + 2);
        sampleRate = _le32(bytes, offset + 4);
        bitsPerSample = chunkSize >= 16 ? _le16(bytes, offset + 14) : 16;
      } else if (chunkId == 'data') {
        dataOffset = offset;
        dataSize = chunkSize;
        break;
      }

      offset += chunkSize + (chunkSize.isOdd ? 1 : 0);
    }

    if (dataOffset == null) return null;

    return _WavInfo(
      dataOffset: dataOffset,
      dataSize: dataSize,
      sampleRate: sampleRate,
      numChannels: numChannels,
      bitsPerSample: bitsPerSample,
    );
  }

  static int _le16(Uint8List bytes, int offset) =>
      bytes[offset] | (bytes[offset + 1] << 8);

  static int _le32(Uint8List bytes, int offset) =>
      bytes[offset] |
      (bytes[offset + 1] << 8) |
      (bytes[offset + 2] << 16) |
      (bytes[offset + 3] << 24);

  /// Compact storage for [FileMessage.metadata].
  static String encodePeaks(List<double> peaks) {
    return base64Encode(
      Uint8List.fromList(
        peaks.map((p) => (p.clamp(0, 1) * 255).round()).toList(),
      ),
    );
  }

  static List<double>? decodePeaks(
    String? encoded, {
    int binCount = defaultBinCount,
  }) {
    if (encoded == null || encoded.isEmpty) return null;
    try {
      final bytes = base64Decode(encoded);
      if (bytes.isEmpty) return null;
      return bytes.map((b) => (b / 255).clamp(0.05, 1.0)).toList();
    } catch (_) {
      return null;
    }
  }
}

class _WavInfo {
  final int dataOffset;
  final int dataSize;
  final int sampleRate;
  final int numChannels;
  final int bitsPerSample;

  const _WavInfo({
    required this.dataOffset,
    required this.dataSize,
    required this.sampleRate,
    required this.numChannels,
    required this.bitsPerSample,
  });
}
