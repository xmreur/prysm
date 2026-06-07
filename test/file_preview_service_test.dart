import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/services/file_preview_service.dart';
import 'package:prysm/util/readable_file_policy.dart';

void main() {
  test('text preview truncates to snippet lines', () async {
    final bytes = utf8.encode('line1\nline2\nline3\nline4\nline5\nline6\nline7\nline8\nline9');
    final preview = await FilePreviewService.buildPreview(
      fileName: 'sample.txt',
      bytes: Uint8List.fromList(bytes),
      inline: true,
    );

    expect(preview.category, FilePreviewCategory.text);
    expect(preview.text!.lines.length, ReadableFilePolicy.textSnippetLines);
    expect(preview.text!.lines.first, 'line1');
  });

  test('blocked files return blocked preview data', () async {
    final preview = await FilePreviewService.buildPreview(
      fileName: 'malware.exe',
      bytes: Uint8List.fromList([1, 2, 3]),
      inline: true,
    );
    expect(preview.category, FilePreviewCategory.blocked);
  });
}
