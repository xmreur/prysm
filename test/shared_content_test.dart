import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/models/shared_content.dart';
import 'package:prysm/util/file_transfer_policy.dart';

void main() {
  group('SharedContent file limits', () {
    test('max file size policy rejects oversized payloads', () {
      final oversized = FileTransferPolicy.maxFileSizeBytes + 1;
      expect(FileTransferPolicy.isWithinMaxFileSize(oversized), isFalse);
      expect(
        FileTransferPolicy.isWithinMaxFileSize(FileTransferPolicy.maxFileSizeBytes),
        isTrue,
      );
    });

    test('text content is identified correctly', () {
      const content = SharedContent(
        kind: SharedContentKind.text,
        text: 'shared note',
      );
      expect(content.isText, isTrue);
      expect(content.isFile, isFalse);
    });
  });
}
