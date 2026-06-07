import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/util/pptx_text_extractor.dart';

void main() {
  test('extracts slide text from pptx bytes', () {
    final archive = Archive()
      ..addFile(
        ArchiveFile(
          'ppt/slides/slide1.xml',
          0,
          utf8.encode(
            '<p:sld><a:t>Hello slide</a:t><a:t>Second line</a:t></p:sld>',
          ),
        ),
      );

    final bytes = Uint8List.fromList(ZipEncoder().encode(archive)!);
    final text = PptxTextExtractor.extract(bytes);

    expect(text, contains('Hello slide'));
    expect(text, contains('Second line'));
  });
}
