import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:prysm/services/call/call_pcm_playback.dart';
import 'package:prysm/services/call/pcm_jitter_buffer.dart';

/// Mixes per-sender PCM jitter buffers into one playback stream.
class GroupAudioMixer {
  GroupAudioMixer({
    required this.sampleRate,
    required this.channels,
    required this.playback,
    this.chunkMs = 40,
    this.minStartMs = 60,
    this.maxLatencyMs = 180,
  });

  final int sampleRate;
  final int channels;
  final CallPcmPlayback playback;
  final int chunkMs;
  final int minStartMs;
  final int maxLatencyMs;

  final Map<int, PcmJitterBuffer> _buffers = {};
  Timer? _timer;
  bool _running = false;

  int get _chunkBytes => sampleRate * channels * 2 * chunkMs ~/ 1000;

  void addSender(int slot) {
    _buffers.putIfAbsent(
      slot,
      () => PcmJitterBuffer(
        sampleRate: sampleRate,
        channels: channels,
        minStartMs: minStartMs,
        chunkMs: chunkMs,
        maxLatencyMs: maxLatencyMs,
      ),
    );
  }

  void removeSender(int slot) {
    _buffers.remove(slot)?.reset();
  }

  void pushPcm(int slot, Uint8List pcm) {
    addSender(slot);
    _buffers[slot]!.push(pcm);
  }

  Future<void> start() async {
    if (_running) return;
    _running = true;
    await playback.start(sampleRate: sampleRate, channels: channels);
    _timer = Timer.periodic(Duration(milliseconds: chunkMs), (_) => mixOnce());
  }

  @visibleForTesting
  void mixOnce() {
    if (!_running) return;
    final chunkBytes = _chunkBytes;
    if (chunkBytes <= 0) return;
    if (_buffers.isEmpty) {
      playback.playPcm(Uint8List(chunkBytes));
      return;
    }

    final mixed = Int16List(chunkBytes ~/ 2);
    for (final buffer in _buffers.values) {
      final chunk = buffer.take() ?? Uint8List(chunkBytes);
      final samples = Int16List.view(
        chunk.buffer,
        chunk.offsetInBytes,
        chunk.lengthInBytes ~/ 2,
      );
      final n = min(samples.length, mixed.length);
      for (var i = 0; i < n; i++) {
        mixed[i] = (mixed[i] + samples[i]).clamp(-32768, 32767);
      }
    }
    playback.playPcm(
      mixed.buffer.asUint8List(mixed.offsetInBytes, mixed.lengthInBytes),
    );
  }

  Future<void> stop() async {
    _running = false;
    _timer?.cancel();
    _timer = null;
    for (final buffer in _buffers.values) {
      buffer.reset();
    }
    _buffers.clear();
    await playback.stop();
  }
}
