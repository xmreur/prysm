import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/services/call/opus_codec.dart';

void main() {
  test('loads libopus on Linux via DynamicLibrary', () async {
    if (!Platform.isLinux) return;

    final loaded = await OpusCodec.ensureLoaded();
    expect(
      loaded,
      isTrue,
      reason: OpusCodec.lastLoadError ?? 'unknown load error',
    );

    final codec = await OpusCodec.create();
    expect(codec, isNotNull);
    codec?.dispose();
  }, skip: Platform.isLinux ? false : 'Linux only');
}
