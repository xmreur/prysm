import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/services/call/audio_engine.dart';

void main() {
  test('chainAudioSend preserves capture order with slow encrypt', () async {
    final sent = <int>[];
  var chain = Future<void>.value();

    final tasks = <Future<Uint8List> Function()>[
      () async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        return Uint8List.fromList([1]);
      },
      () async {
        await Future<void>.delayed(const Duration(milliseconds: 5));
        return Uint8List.fromList([2]);
      },
      () async {
        await Future<void>.delayed(const Duration(milliseconds: 30));
        return Uint8List.fromList([3]);
      },
    ];

    for (final task in tasks) {
      chain = chainAudioSend(chain, task, (frame) => sent.add(frame[0]));
    }

    await chain;
    expect(sent, [1, 2, 3]);
  });
}
