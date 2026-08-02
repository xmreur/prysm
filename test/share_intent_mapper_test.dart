import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/models/shared_content.dart';
import 'package:prysm/services/share_intent_service.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

void main() {
  group('ShareIntentService.mapMediaFile', () {
    test('maps text payloads', () {
      final content = ShareIntentService.mapMediaFile(
        SharedMediaFile(path: 'hello world', type: SharedMediaType.text),
      );

      expect(content?.kind, SharedContentKind.text);
      expect(content?.text, 'hello world');
    });

    test('maps url payloads as text', () {
      final content = ShareIntentService.mapMediaFile(
        SharedMediaFile(
          path: 'https://example.com',
          type: SharedMediaType.url,
        ),
      );

      expect(content?.kind, SharedContentKind.text);
      expect(content?.text, 'https://example.com');
    });

    test('maps image files', () {
      final content = ShareIntentService.mapMediaFile(
        SharedMediaFile(
          path: '/tmp/photo.jpg',
          type: SharedMediaType.image,
          mimeType: 'image/jpeg',
        ),
      );

      expect(content?.kind, SharedContentKind.file);
      expect(content?.filePath, '/tmp/photo.jpg');
      expect(content?.fileName, 'photo.jpg');
      expect(content?.mimeType, 'image/jpeg');
    });

    test('ignores empty payloads', () {
      expect(
        ShareIntentService.mapMediaFile(
          SharedMediaFile(path: '   ', type: SharedMediaType.text),
        ),
        isNull,
      );
    });
  });
}
