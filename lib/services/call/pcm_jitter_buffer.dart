import 'dart:typed_data';

/// Smooths bursty network PCM delivery before playback.
class PcmJitterBuffer {
  PcmJitterBuffer({
    required this.sampleRate,
    required this.channels,
    this.minStartMs = 80,
    this.chunkMs = 40,
    this.maxLatencyMs = 200,
  });

  final int sampleRate;
  final int channels;
  final int minStartMs;
  final int chunkMs;
  final int maxLatencyMs;

  final List<int> _queue = [];
  bool _primed = false;

  int get _bytesPerMs => sampleRate * channels * 2 ~/ 1000;

  void push(Uint8List pcm) {
    _queue.addAll(pcm);
    final maxBytes = _bytesPerMs * maxLatencyMs;
    if (_queue.length > maxBytes) {
      _queue.removeRange(0, _queue.length - maxBytes);
    }
  }

  Uint8List? take() {
    final minStartBytes = _bytesPerMs * minStartMs;
    final chunkBytes = _bytesPerMs * chunkMs;
    if (!_primed) {
      if (_queue.length < minStartBytes) return null;
      _primed = true;
    }
    if (_queue.length < chunkBytes) return null;
    final chunk = Uint8List.fromList(_queue.sublist(0, chunkBytes));
    _queue.removeRange(0, chunkBytes);
    return chunk;
  }

  void reset() {
    _queue.clear();
    _primed = false;
  }
}
