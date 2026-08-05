// Security regression tests for H1 (path traversal in blob storage and file
// downloads): attacker-controlled message ids and file names must never reach
// a File() path outside the designated folders.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:prysm/util/download_location.dart';
import 'package:prysm/util/message_blob_store.dart';

/// Fails if [value] contains a surrogate code unit without its partner.
void expectUnpairedSurrogates(String value) {
  final units = value.codeUnits;
  for (var i = 0; i < units.length; i++) {
    final unit = units[i];
    if (unit >= 0xd800 && unit <= 0xdbff) {
      final hasLowPartner = i + 1 < units.length &&
          units[i + 1] >= 0xdc00 &&
          units[i + 1] <= 0xdfff;
      expect(
        hasLowPartner,
        isTrue,
        reason: 'high surrogate 0x${unit.toRadixString(16)} at index $i of '
            '"$value" has no low surrogate partner',
      );
      i++;
    } else if (unit >= 0xdc00 && unit <= 0xdfff) {
      fail('lone low surrogate 0x${unit.toRadixString(16)} at index $i of '
          '"$value"');
    }
  }
}

void main() {
  late Directory docsDir;

  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    // MessageBlobStore shells out to path_provider via
    // getApplicationDocumentsDirectory.
    docsDir = Directory.systemTemp.createTempSync('path_traversal_test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async {
        if (call.method == 'getApplicationDocumentsDirectory') {
          return docsDir.path;
        }
        return null;
      },
    );
  });

  tearDownAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    docsDir.deleteSync(recursive: true);
  });

  // Creates a real file just outside the (fake) documents dir so tests can
  // prove a traversal id no longer reaches it.
  File outsideSentinel(String name) {
    final file = File(p.join(docsDir.parent.path, '$name${p.basename(docsDir.path)}'));
    file.writeAsStringSync('sentinel');
    addTearDown(() {
      if (file.existsSync()) file.deleteSync();
    });
    return file;
  }

  group('MessageBlobStore path traversal guard', () {
    test('save rejects traversal ids and writes nothing outside message_blobs/',
        () async {
      // Clear any residue from a previous (vulnerable) run; a reverted guard
      // would re-create the file and fail the assertion below.
      final escapeTarget = File(p.join(docsDir.parent.path, 'prysm_pwned_h1'));
      if (escapeTarget.existsSync()) escapeTarget.deleteSync();

      await expectLater(
        MessageBlobStore.save('../../prysm_pwned_h1', 'x'),
        throwsArgumentError,
      );
      // Sink proof: the payload must not appear in the docs dir's parent.
      expect(escapeTarget.existsSync(), isFalse);
    });

    test('prepareForStorage rejects traversal ids for oversized payloads',
        () async {
      final oversized = 'x' * (MessageBlobStore.inlineThreshold + 1);
      await expectLater(
        MessageBlobStore.prepareForStorage('../../evil', oversized),
        throwsArgumentError,
      );
    });

    test('save rejects empty, dot, dotdot, and separator ids', () async {
      for (final id in <String>['', '.', '..', 'a/b', r'a\b']) {
        await expectLater(
          MessageBlobStore.save(id, 'x'),
          throwsArgumentError,
          reason: 'id: $id',
        );
      }
    });

    test('exists returns false for traversal ids, even when the target exists',
        () async {
      final sentinel = outsideSentinel('h1_exists_');
      expect(
        await MessageBlobStore.exists('../../${p.basename(sentinel.path)}'),
        isFalse,
      );
      expect(await MessageBlobStore.exists('../../etc/passwd'), isFalse);
    });

    test('delete is a no-op for traversal ids and leaves real files untouched',
        () async {
      final sentinel = outsideSentinel('h1_delete_');
      await MessageBlobStore.delete('../../${p.basename(sentinel.path)}');
      expect(sentinel.existsSync(), isTrue);
      expect(sentinel.readAsStringSync(), 'sentinel');
      // The exact case from the scan report must complete without throwing.
      await MessageBlobStore.delete('../../etc/passwd');
    });

    test('resolve returns null for traversal markers', () async {
      // The unguarded code would read the sentinel's content back.
      final sentinel = outsideSentinel('h1_resolve_');
      expect(
        await MessageBlobStore.resolve('blob:../../${p.basename(sentinel.path)}'),
        isNull,
      );
      expect(await MessageBlobStore.resolve('blob:../../etc/passwd'), isNull);
    });

    test('round-trips legitimate ids', () async {
      for (final id in <String>['abc-123', 'group1::wire-9', 'a.b_c']) {
        await MessageBlobStore.save(id, 'payload-$id');
        expect(await MessageBlobStore.exists(id), isTrue, reason: id);
        expect(await MessageBlobStore.read(id), 'payload-$id', reason: id);
        expect(await MessageBlobStore.resolve('blob:$id'), 'payload-$id',
            reason: id);
        await MessageBlobStore.delete(id);
        expect(await MessageBlobStore.exists(id), isFalse, reason: id);
      }
    });
  });

  group('DownloadLocation.sanitizeFileName', () {
    test('strips directory traversal from peer file names', () {
      expect(
        DownloadLocation.sanitizeFileName(
            '../../../home/u/.config/autostart/x.desktop'),
        'x.desktop',
      );
      expect(DownloadLocation.sanitizeFileName(r'evil\..\x.png'), 'x.png');
      expect(DownloadLocation.sanitizeFileName('a/b.txt'), 'b.txt');
    });

    test('maps empty and dot names to a safe default', () {
      expect(DownloadLocation.sanitizeFileName('..'), 'download');
      expect(DownloadLocation.sanitizeFileName(''), 'download');
      expect(DownloadLocation.sanitizeFileName('.'), 'download');
    });

    test('leaves ordinary names untouched', () {
      expect(DownloadLocation.sanitizeFileName('photo 1.jpg'), 'photo 1.jpg');
    });

    test('replaces reserved and control characters with underscores', () {
      expect(DownloadLocation.sanitizeFileName('a:b?c.txt'), 'a_b_c.txt');
      expect(DownloadLocation.sanitizeFileName('a\u0001b.txt'), 'a_b.txt');
    });

    test('caps long names at 200 chars preserving the extension', () {
      final result = DownloadLocation.sanitizeFileName('${'x' * 500}.png');
      expect(result.length, lessThanOrEqualTo(200));
      expect(result.endsWith('.png'), isTrue);
    });

    test('does not split a surrogate pair when capping long names', () {
      // 195 ASCII chars + a 2-code-unit emoji + '.png' = 201 code units. The
      // old substring(0, 196) cut kept the emoji's high surrogate and dropped
      // its low partner, leaving a lone surrogate the filesystem mangles.
      final result =
          DownloadLocation.sanitizeFileName('${'x' * 195}\u{1F600}.png');
      expect(result, '${'x' * 195}.png');
      expect(result.length, lessThanOrEqualTo(200));
      expect(result.endsWith('.png'), isTrue);
      expectUnpairedSurrogates(result);
    });

    test('does not split a surrogate pair inside a long extension', () {
      // '.x' * 18 + emoji = a 21-code-unit extension; the old substring(0, 20)
      // cut kept the high surrogate of the pair at boundary 19/20.
      final result = DownloadLocation.sanitizeFileName(
          '${'a' * 200}.${'x' * 18}\u{1F600}');
      expect(result.length, lessThanOrEqualTo(200));
      expect(p.extension(result).length, lessThanOrEqualTo(20));
      expectUnpairedSurrogates(result);
    });
  });
}
