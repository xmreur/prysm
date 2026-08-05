import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/services/call/opus_codec.dart';

/// The pinned sha256 of the macOS libopus artifact
/// (`xmreur/prysm-resources` `tor/exec/macos/libopus.dylib`), recorded by the
/// security scan on 2026-08-05. Must match [OpusCodec.pinnedOpusSha256]; the
/// behaviour-level test below enforces that.
const _pinnedOpusSha256 =
    '435581a316f3dd41982f3101caa6be6ec974572e31765cd0e29c7cbe30198609';

void main() {
  group('OpusCodec.isTrustedOpusPayload', () {
    test('rejects a payload of the wrong length', () {
      expect(OpusCodec.isTrustedOpusPayload(<int>[]), isFalse);
      expect(OpusCodec.isTrustedOpusPayload(Uint8List(100)), isFalse);
      expect(
        OpusCodec.isTrustedOpusPayload(
          Uint8List(OpusCodec.pinnedOpusSizeBytes + 1),
        ),
        isFalse,
      );
    });

    test('rejects a same-size payload that is not the artifact', () {
      // All zeros at exactly the pinned size. This is the case that would
      // pass if the length check survived but the digest check were dropped.
      final zeros = Uint8List(OpusCodec.pinnedOpusSizeBytes);
      expect(OpusCodec.isTrustedOpusPayload(zeros), isFalse);
    });
  });

  group('pinned artifact constant', () {
    test('is exported with the digest recorded by the security scan', () {
      expect(
        OpusCodec.pinnedOpusSha256,
        _pinnedOpusSha256,
        reason: 'OpusCodec pinned digest drifted from the recorded artifact '
            'digest (update both, or the artifact changed upstream)',
      );
      expect(OpusCodec.pinnedOpusSha256, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(OpusCodec.pinnedOpusSizeBytes, greaterThan(0));
    });

    test('is not the digest of an all-zero payload of the artifact size', () {
      final zeroDigest =
          sha256.convert(Uint8List(OpusCodec.pinnedOpusSizeBytes)).toString();
      expect(
        zeroDigest,
        isNot(OpusCodec.pinnedOpusSha256),
        reason: 'pinned digest must not equal the digest of an all-zero '
            'payload (guards against a lazy placeholder constant)',
      );
    });
  });
}
