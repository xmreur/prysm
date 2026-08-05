import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/services/call/opus_codec.dart';

/// The pinned sha256 of the macOS libopus artifact
/// (`xmreur/prysm-resources` `tor/exec/macos/libopus.dylib`), recorded by the
/// security scan on 2026-08-05. Must stay in sync with
/// [OpusCodec._opusSha256]; the source-level test below enforces that.
const _pinnedOpusSha256 =
    '435581a316f3dd41982f3101caa6be6ec974572e31765cd0e29c7cbe30198609';

const _opusSizeBytes = 357824;

void main() {
  group('OpusCodec.isTrustedOpusPayload', () {
    test('rejects a payload of the wrong length', () {
      expect(OpusCodec.isTrustedOpusPayload(<int>[]), isFalse);
      expect(OpusCodec.isTrustedOpusPayload(Uint8List(100)), isFalse);
      expect(
        OpusCodec.isTrustedOpusPayload(Uint8List(_opusSizeBytes + 1)),
        isFalse,
      );
    });

    test('rejects a same-size payload that is not the artifact', () {
      // All zeros at exactly the pinned size. This is the case that would
      // pass if the length check survived but the digest check were dropped.
      final zeros = Uint8List(_opusSizeBytes);
      expect(OpusCodec.isTrustedOpusPayload(zeros), isFalse);
    });
  });

  group('pinned artifact constant', () {
    test('is a 64-char lowercase hex literal in opus_codec.dart', () {
      final source =
          File('lib/services/call/opus_codec.dart').readAsStringSync();
      final match =
          RegExp(r"_opusSha256\s*=\s*'([0-9a-f]{64})'").firstMatch(source);
      expect(
        match,
        isNotNull,
        reason: 'OpusCodec._opusSha256 must be declared as a 64-char '
            'lowercase hex literal (placeholder like 435581a3...8609 fails)',
      );
      expect(
        match!.group(1),
        _pinnedOpusSha256,
        reason: 'OpusCodec._opusSha256 drifted from the pinned artifact digest',
      );
    });

    test('is not the digest of an all-zero payload of the artifact size', () {
      final zeroDigest = sha256.convert(Uint8List(_opusSizeBytes)).toString();
      expect(
        zeroDigest,
        isNot(_pinnedOpusSha256),
        reason: 'pinned digest must not equal the digest of an all-zero '
            'payload (guards against a lazy placeholder constant)',
      );
      expect(_pinnedOpusSha256, matches(RegExp(r'^[0-9a-f]{64}$')));
    });
  });
}
