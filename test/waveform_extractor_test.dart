import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/util/waveform_extractor.dart';

Uint8List _buildWav(List<int> pcmSamples16Le) {
  final dataSize = pcmSamples16Le.length;
  final fileSize = 36 + dataSize;
  final header = BytesBuilder();
  header.add('RIFF'.codeUnits);
  header.add(_le32(fileSize));
  header.add('WAVE'.codeUnits);
  header.add('fmt '.codeUnits);
  header.add(_le32(16));
  header.add(_le16(1)); // PCM
  header.add(_le16(1)); // mono
  header.add(_le32(16000));
  header.add(_le32(32000));
  header.add(_le16(2));
  header.add(_le16(16));
  header.add('data'.codeUnits);
  header.add(_le32(dataSize));
  header.add(pcmSamples16Le);
  return header.toBytes();
}

List<int> _le16(int v) => [v & 0xff, (v >> 8) & 0xff];
List<int> _le32(int v) => [v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff];

void main() {
  test('extractPeaks returns fixed bin count', () {
    final pcm = List<int>.generate(3200, (i) {
      final s = (sin(i / 10) * 20000).round();
      return s & 0xff;
    }).expand((b) => [b, 0]).toList();
    final wav = _buildWav(pcm);
    final peaks = WaveformExtractor.extractPeaks(wav, binCount: 48);
    expect(peaks.length, 48);
    expect(peaks.every((p) => p >= 0 && p <= 1), isTrue);
    expect(peaks.any((p) => p > 0.2), isTrue);
  });

  test('silence yields flat placeholder peaks', () {
    final pcm = List<int>.filled(3200, 0);
    final peaks = WaveformExtractor.extractPeaks(_buildWav(pcm));
    expect(peaks.every((p) => p == 0.15), isTrue);
  });

  test('estimateDurationMs matches PCM size', () {
    final pcm = List<int>.filled(32000, 0); // 1 second at 16kHz mono 16-bit
    final ms = WaveformExtractor.estimateDurationMs(_buildWav(pcm));
    expect(ms, 1000);
  });

  test('extractPeaks handles LIST chunk before data', () {
    final pcm = List<int>.generate(3200, (i) {
      final s = (sin(i / 10) * 20000).round();
      return s & 0xff;
    }).expand((b) => [b, 0]).toList();

    final listSize = 20; // INFO + ISFT sub-chunk
    final fileSize = 12 + 24 + 8 + listSize + 8 + pcm.length;

    final header = BytesBuilder();
    header.add('RIFF'.codeUnits);
    header.add(_le32(fileSize - 8));
    header.add('WAVE'.codeUnits);
    header.add('fmt '.codeUnits);
    header.add(_le32(16));
    header.add(_le16(1));
    header.add(_le16(1));
    header.add(_le32(16000));
    header.add(_le32(32000));
    header.add(_le16(2));
    header.add(_le16(16));
    header.add('LIST'.codeUnits);
    header.add(_le32(listSize));
    header.add('INFO'.codeUnits);
    header.add('ISFT'.codeUnits);
    header.add(_le32(8));
    header.add('Lavf62.1'.codeUnits);
    header.add('data'.codeUnits);
    header.add(_le32(pcm.length));
    header.add(pcm);

    final wav = header.toBytes();
    final peaks = WaveformExtractor.extractPeaks(wav);
    expect(peaks.any((p) => p > 0.2), isTrue);
    expect(WaveformExtractor.estimateDurationMs(wav), 200);
  });

  test('encode and decode peaks round-trip', () {
    final original = List<double>.generate(48, (i) => i / 47);
    final encoded = WaveformExtractor.encodePeaks(original);
    final decoded = WaveformExtractor.decodePeaks(encoded);
    expect(decoded, isNotNull);
    expect(decoded!.length, 48);
  });
}
