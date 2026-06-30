import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/util/chat_attachment_ingress.dart';

void main() {
  group('ChatAttachmentIngress.isImageFileName', () {
    test('returns true for common image extensions', () {
      expect(ChatAttachmentIngress.isImageFileName('photo.png'), isTrue);
      expect(ChatAttachmentIngress.isImageFileName('IMG.JPG'), isTrue);
      expect(ChatAttachmentIngress.isImageFileName('pic.webp'), isTrue);
      expect(ChatAttachmentIngress.isImageFileName('anim.gif'), isTrue);
      expect(ChatAttachmentIngress.isImageFileName('scan.heic'), isTrue);
    });

    test('returns false for non-image files', () {
      expect(ChatAttachmentIngress.isImageFileName('doc.pdf'), isFalse);
      expect(ChatAttachmentIngress.isImageFileName('archive.zip'), isFalse);
      expect(ChatAttachmentIngress.isImageFileName('notes.txt'), isFalse);
    });
  });

  group('ChatAttachmentIngress.prepareImageBytes', () {
    test('leaves small images unchanged', () async {
      final bytes = Uint8List.fromList([0, 1, 2, 3]);
      final prepared = await ChatAttachmentIngress.prepareImageBytes(bytes);
      expect(prepared, bytes);
    });
  });
}
