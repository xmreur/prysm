import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/util/format_file_size.dart';

void main() {
  group('formatFileSize', () {
    test('formats bytes', () {
      expect(formatFileSize(0), '0 B');
      expect(formatFileSize(512), '512 B');
    });

    test('formats kilobytes', () {
      expect(formatFileSize(1024), '1.0 KB');
      expect(formatFileSize(1536), '1.5 KB');
    });

    test('formats megabytes', () {
      expect(formatFileSize(1024 * 1024), '1.0 MB');
      expect(formatFileSize(1024 * 1024 * 3), '3.0 MB');
    });
  });
}
