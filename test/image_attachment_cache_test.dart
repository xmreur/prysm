import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/constants/media_constants.dart';
import 'package:prysm/services/image_attachment_cache.dart';

/// Minimal valid 1x1 PNG.
final _pngBytes = Uint8List.fromList([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
]);

final _jpegBytes = Uint8List.fromList([
  0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46,
  0x49, 0x46, 0x00, 0x01, 0x01, 0x00, 0x00, 0x01,
  0x00, 0x01, 0x00, 0x00, 0xFF, 0xD9,
]);

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
  });

  setUp(() {
    ImageAttachmentCache.resetForTest();
  });

  test('isDeferredImageSource recognizes prysm-image scheme', () {
    const id = 'msg-1';
    final source = deferredImageSourceFor(id);
    expect(isDeferredImageSource(source), isTrue);
    expect(messageIdFromDeferredImageSource(source), id);
  });

  test('sniffImageMimeType detects PNG and JPEG', () {
    expect(ImageAttachmentCache.sniffImageMimeType(_pngBytes), 'image/png');
    expect(ImageAttachmentCache.sniffImageMimeType(_jpegBytes), 'image/jpeg');
  });

  test('inline bytes resolve without calling decrypt', () async {
    var decryptCalls = 0;
    final result = await ImageAttachmentCache.resolve(
      messageId: 'inline-1',
      decrypt: () async {
        decryptCalls++;
        return _pngBytes;
      },
      inlineBytes: _pngBytes,
    );
    expect(decryptCalls, 0);
    expect(result.bytes, _pngBytes);
    expect(result.mimeType, 'image/png');
  });

  test('concurrent resolve deduplicates decrypt', () async {
    var decryptCalls = 0;
    Future<Uint8List> decrypt() async {
      decryptCalls++;
      await Future<void>.delayed(const Duration(milliseconds: 50));
      return _pngBytes;
    }

    final a = ImageAttachmentCache.resolve(
      messageId: 'dedup-1',
      decrypt: decrypt,
    );
    final b = ImageAttachmentCache.resolve(
      messageId: 'dedup-1',
      decrypt: decrypt,
    );

    final results = await Future.wait([a, b]);
    expect(decryptCalls, 1);
    expect(results[0].bytes, results[1].bytes);
    expect(ImageAttachmentCache.inflightCount(), 0);
  });

  test('disk cache is reused on second resolve', () async {
    final tempDir = await Directory.systemTemp.createTemp('img_cache_test');
    addTearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });
    ImageAttachmentCache.setDiskDirForTest(tempDir.path);

    var decryptCalls = 0;
    Future<Uint8List> decrypt() async {
      decryptCalls++;
      return _pngBytes;
    }

    await ImageAttachmentCache.resolve(messageId: 'disk-1', decrypt: decrypt);
    expect(decryptCalls, 1);
    ImageAttachmentCache.resetForTest();
    ImageAttachmentCache.setDiskDirForTest(tempDir.path);

    await ImageAttachmentCache.resolve(messageId: 'disk-1', decrypt: decrypt);
    expect(decryptCalls, 1);
    expect(await File('${tempDir.path}/disk-1.img').exists(), isTrue);
  });
}
