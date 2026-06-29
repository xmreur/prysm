import 'dart:math';
import 'dart:typed_data';

/// High-pass filter, adaptive noise floor, and gate for mic capture.
class PcmCaptureProcessor {
  PcmCaptureProcessor({
    this.sampleRate = 16000,
    this.highPassHz = 100,
    this.calibrationFrames = 25,
    this.openRatio = 2.0,
    this.closeRatio = 1.4,
    this.smoothingFrames = 3,
    this.minNoiseFloor = 50,
  }) : _highPassAlpha = _alphaForCutoff(sampleRate, highPassHz);

  final int sampleRate;
  final double highPassHz;
  final int calibrationFrames;
  final double openRatio;
  final double closeRatio;
  final int smoothingFrames;
  final double minNoiseFloor;

  final double _highPassAlpha;

  double _hpPrevIn = 0;
  double _hpPrevOut = 0;

  final List<double> _calibrationRms = [];
  double _noiseFloor = 200;
  bool _calibrated = false;

  bool _gateOpen = false;
  double _gateMix = 0;
  double _speechRms = 0;

  bool get gateOpen => _gateOpen;

  double get speechRms => _speechRms;

  bool get isCalibrated => _calibrated;

  void reset() {
    _hpPrevIn = 0;
    _hpPrevOut = 0;
    _calibrationRms.clear();
    _noiseFloor = 200;
    _calibrated = false;
    _gateOpen = false;
    _gateMix = 0;
    _speechRms = 0;
  }

  Int16List process(Int16List pcm) {
    if (pcm.isEmpty) return pcm;

    final filtered = _highPass(pcm);
    final rms = _rms(filtered);
    _speechRms = rms;
    _updateNoiseFloor(rms);
    _updateGate(rms);
    return _applyGate(filtered);
  }

  static double _alphaForCutoff(int sampleRate, double cutoffHz) {
    final dt = 1.0 / sampleRate;
    final rc = 1.0 / (2 * pi * cutoffHz);
    return rc / (rc + dt);
  }

  Int16List _highPass(Int16List pcm) {
    final out = Int16List(pcm.length);
    var prevIn = _hpPrevIn;
    var prevOut = _hpPrevOut;
    final alpha = _highPassAlpha;

    for (var i = 0; i < pcm.length; i++) {
      final x = pcm[i].toDouble();
      final y = alpha * (prevOut + x - prevIn);
      out[i] = y.round().clamp(-32768, 32767);
      prevIn = x;
      prevOut = y;
    }

    _hpPrevIn = prevIn;
    _hpPrevOut = prevOut;
    return out;
  }

  double _rms(Int16List pcm) {
    var sumSq = 0.0;
    for (final sample in pcm) {
      sumSq += sample * sample;
    }
    return sqrt(sumSq / pcm.length);
  }

  void _updateNoiseFloor(double rms) {
    if (!_calibrated) {
      _calibrationRms.add(rms);
      if (_calibrationRms.length >= calibrationFrames) {
        final sorted = List<double>.from(_calibrationRms)..sort();
        _noiseFloor = sorted[sorted.length ~/ 2];
        if (_noiseFloor < minNoiseFloor) {
          _noiseFloor = minNoiseFloor;
        }
        _calibrated = true;
      }
      return;
    }

    if (rms < _noiseFloor * closeRatio) {
      _noiseFloor = _noiseFloor * 0.995 + rms * 0.005;
      if (_noiseFloor < minNoiseFloor) {
        _noiseFloor = minNoiseFloor;
      }
    }
  }

  void _updateGate(double rms) {
    if (!_calibrated) {
      _gateOpen = false;
      _gateMix = 0;
      return;
    }

    final openThreshold = _noiseFloor * openRatio;
    final closeThreshold = _noiseFloor * closeRatio;

    if (!_gateOpen) {
      if (rms >= openThreshold) {
        _gateOpen = true;
      }
    } else if (rms < closeThreshold) {
      _gateOpen = false;
    }

    final target = _gateOpen ? 1.0 : 0.0;
    final step = 1.0 / smoothingFrames;
    if (_gateMix < target) {
      _gateMix = min(target, _gateMix + step);
    } else if (_gateMix > target) {
      _gateMix = max(target, _gateMix - step);
    }
  }

  Int16List _applyGate(Int16List pcm) {
    if (_gateMix >= 0.999) return pcm;

    final out = Int16List(pcm.length);
    if (_gateMix <= 0.001) {
      return out;
    }

    for (var i = 0; i < pcm.length; i++) {
      out[i] = (pcm[i] * _gateMix).round().clamp(-32768, 32767);
    }
    return out;
  }
}
