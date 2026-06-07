import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

class PptxTextExtractor {
  PptxTextExtractor._();

  static String extract(Uint8List bytes) {
    try {
      final archive = ZipDecoder().decodeBytes(bytes);
      final slideFiles = archive.files
          .where(
            (f) =>
                f.isFile &&
                f.name.startsWith('ppt/slides/slide') &&
                f.name.endsWith('.xml'),
          )
          .toList()
        ..sort((a, b) => a.name.compareTo(b.name));

      final buffer = StringBuffer();
      for (final slide in slideFiles) {
        final xml = utf8.decode(slide.content as List<int>);
        for (final match in RegExp(r'<a:t[^>]*>([^<]*)</a:t>').allMatches(xml)) {
          final text = match.group(1)?.trim();
          if (text != null && text.isNotEmpty) {
            buffer.writeln(text);
          }
        }
      }
      return buffer.toString().trim();
    } catch (_) {
      return '';
    }
  }
}
