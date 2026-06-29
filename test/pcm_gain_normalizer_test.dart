import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/services/call/pcm_gain_normalizer.dart';

double _rms(Int16List pcm) {
  var sum = 0.0;
  for (final s in pcm) {
    sum += s * s;
  }
  return sqrt(sum / pcm.length);
}

void main() {
  test('boosts quiet frames toward target level', () {
    final normalizer = PcmGainNormalizer(targetRms: 4000);
    final pcm = Int16List(320);
    for (var i = 0; i < pcm.length; i++) {
      pcm[i] = (120 * sin(2 * pi * i / 40)).round();
    }

    final before = _rms(pcm);
    var after = before;
    for (var i = 0; i < 30; i++) {
      after = _rms(normalizer.normalize(pcm));
    }

    expect(before, lessThan(500));
    expect(after, greaterThan(before * 8));
    expect(after, greaterThan(800));
  });

  test('attenuates loud frames', () {
    final normalizer = PcmGainNormalizer(targetRms: 4000, maxPeak: 28000);
    final pcm = Int16List(320);
    for (var i = 0; i < pcm.length; i++) {
      pcm[i] = (28000 * sin(2 * pi * i / 40)).round();
    }

    var out = pcm;
    for (var i = 0; i < 8; i++) {
      out = normalizer.normalize(out);
    }

    expect(out.reduce(max), lessThanOrEqualTo(28000));
    expect(_rms(out), lessThan(_rms(pcm)));
  });

  test('applyGain false decays internal gain without boosting', () {
    final normalizer = PcmGainNormalizer(targetRms: 4000);
    final pcm = Int16List(320);
    for (var i = 0; i < pcm.length; i++) {
      pcm[i] = (120 * sin(2 * pi * i / 40)).round();
    }

    for (var i = 0; i < 20; i++) {
      normalizer.normalize(pcm);
    }
    final boosted = _rms(normalizer.normalize(pcm));

    for (var i = 0; i < 20; i++) {
      normalizer.normalize(pcm, applyGain: false);
    }
    final afterGate = _rms(normalizer.normalize(pcm, applyGain: false));

    expect(boosted, greaterThan(800));
    expect(afterGate, lessThan(boosted * 0.5));
    expect(afterGate, closeTo(_rms(pcm), 200));
  });
}
