import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/services/call/pcm_capture_processor.dart';
import 'package:prysm/services/call/pcm_gain_normalizer.dart';

Int16List _tone({
  required int samples,
  required double hz,
  required int sampleRate,
  required int amplitude,
}) {
  final pcm = Int16List(samples);
  for (var i = 0; i < samples; i++) {
    pcm[i] = (amplitude * sin(2 * pi * hz * i / sampleRate)).round();
  }
  return pcm;
}

double _rms(Int16List pcm) {
  var sum = 0.0;
  for (final s in pcm) {
    sum += s * s;
  }
  return sqrt(sum / pcm.length);
}

void _calibrate(PcmCaptureProcessor processor, double noiseRms) {
  final noise = _tone(
    samples: 320,
    hz: 400,
    sampleRate: 16000,
    amplitude: noiseRms.round(),
  );
  for (var i = 0; i < 25; i++) {
    processor.process(noise);
  }
  expect(processor.isCalibrated, isTrue);
}

void main() {
  test('high-pass attenuates low frequency more than mid band', () {
    final processor = PcmCaptureProcessor();
    processor.process(
      _tone(samples: 320, hz: 50, sampleRate: 16000, amplitude: 8000),
    );
    final lowRms = processor.speechRms;

    processor.reset();
    processor.process(
      _tone(samples: 320, hz: 400, sampleRate: 16000, amplitude: 8000),
    );
    final midRms = processor.speechRms;

    expect(lowRms, lessThan(midRms * 0.5));
    expect(midRms, greaterThan(1000));
  });

  test('gate stays closed on steady low-level noise after calibration', () {
    final processor = PcmCaptureProcessor();
    _calibrate(processor, 120);

    final noise = _tone(
      samples: 320,
      hz: 400,
      sampleRate: 16000,
      amplitude: 120,
    );
    var out = noise;
    for (var i = 0; i < 10; i++) {
      out = processor.process(noise);
    }

    expect(processor.gateOpen, isFalse);
    expect(_rms(out), lessThan(50));
  });

  test('gate opens on louder burst resembling speech', () {
    final processor = PcmCaptureProcessor();
    _calibrate(processor, 120);

    final speech = _tone(
      samples: 320,
      hz: 300,
      sampleRate: 16000,
      amplitude: 2500,
    );
    Int16List out = speech;
    for (var i = 0; i < 5; i++) {
      out = processor.process(speech);
    }

    expect(processor.gateOpen, isTrue);
    expect(_rms(out), greaterThan(500));
  });

  test('closed gate prevents normalizer from boosting noise frames', () {
    final processor = PcmCaptureProcessor();
    final normalizer = PcmGainNormalizer(targetRms: 4000);

    _calibrate(processor, 200);

    final noise = _tone(
      samples: 320,
      hz: 400,
      sampleRate: 16000,
      amplitude: 200,
    );

    var boostedRms = _rms(noise);
    for (var i = 0; i < 20; i++) {
      final cleaned = processor.process(noise);
      final normalized = normalizer.normalize(
        cleaned,
        applyGain: processor.gateOpen,
      );
      boostedRms = _rms(normalized);
    }

    expect(processor.gateOpen, isFalse);
    expect(boostedRms, lessThan(500));
  });
}
