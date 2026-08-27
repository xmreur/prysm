import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/services/call/call_pcm_playback.dart';
import 'package:prysm/services/call/group_audio_mixer.dart';

class _RecordingPlayback implements CallPcmPlayback {
  final chunks = <Uint8List>[];

  @override
  Future<void> start({required int sampleRate, required int channels}) async {}

  @override
  void playPcm(Uint8List pcm) => chunks.add(Uint8List.fromList(pcm));

  @override
  Future<void> stop() async {}
}

void main() {
  test('sums two senders and clamps', () async {
    final playback = _RecordingPlayback();
    final mixer = GroupAudioMixer(
      sampleRate: 1000,
      channels: 1,
      playback: playback,
      chunkMs: 2,
      minStartMs: 2,
      maxLatencyMs: 20,
    );
    await mixer.start();
    mixer.addSender(0);
    mixer.addSender(1);

    Int16List tone(int value, int samples) =>
        Int16List.fromList(List<int>.filled(samples, value));

    Uint8List asBytes(Int16List pcm) =>
        pcm.buffer.asUint8List(pcm.offsetInBytes, pcm.lengthInBytes);

    // 2ms at 1000Hz mono = 2 samples = 4 bytes. minStart 2ms primes immediately.
    mixer.pushPcm(0, asBytes(tone(20000, 4)));
    mixer.pushPcm(1, asBytes(tone(20000, 4)));
    mixer.mixOnce();

    expect(playback.chunks, isNotEmpty);
    final mixed = Int16List.view(
      playback.chunks.first.buffer,
      playback.chunks.first.offsetInBytes,
      playback.chunks.first.lengthInBytes ~/ 2,
    );
    expect(mixed.first, 32767);

    await mixer.stop();
  });

  test('underrunning sender contributes silence', () async {
    final playback = _RecordingPlayback();
    final mixer = GroupAudioMixer(
      sampleRate: 1000,
      channels: 1,
      playback: playback,
      chunkMs: 2,
      minStartMs: 2,
      maxLatencyMs: 20,
    );
    await mixer.start();
    mixer.addSender(0);
    mixer.addSender(1);

    final pcm = Int16List.fromList(List<int>.filled(4, 100));
    mixer.pushPcm(
      0,
      pcm.buffer.asUint8List(pcm.offsetInBytes, pcm.lengthInBytes),
    );
    mixer.mixOnce();

    expect(playback.chunks, isNotEmpty);
    final mixed = Int16List.view(
      playback.chunks.first.buffer,
      playback.chunks.first.offsetInBytes,
      playback.chunks.first.lengthInBytes ~/ 2,
    );
    expect(mixed.first, 100);

    await mixer.stop();
  });

  test('removed sender is no longer mixed', () async {
    final playback = _RecordingPlayback();
    final mixer = GroupAudioMixer(
      sampleRate: 1000,
      channels: 1,
      playback: playback,
      chunkMs: 2,
      minStartMs: 2,
      maxLatencyMs: 20,
    );
    await mixer.start();
    mixer.addSender(0);

    final pcm = Int16List.fromList(List<int>.filled(4, 50));
    mixer.pushPcm(
      0,
      pcm.buffer.asUint8List(pcm.offsetInBytes, pcm.lengthInBytes),
    );
    mixer.removeSender(0);
    playback.chunks.clear();
    mixer.mixOnce();
    expect(playback.chunks.first.every((b) => b == 0), isTrue);

    await mixer.stop();
  });
}
