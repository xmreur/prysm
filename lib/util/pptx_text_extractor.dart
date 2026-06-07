import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

class PptxTextExtractor {
  PptxTextExtractor._();

  static List<String> extractSlides(Uint8List bytes) {
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

      final slides = <String>[];
      for (final slide in slideFiles) {
        final xml = utf8.decode(slide.content as List<int>);
        final buffer = StringBuffer();
        for (final match
            in RegExp(r'<a:t[^>]*>([^<]*)</a:t>').allMatches(xml)) {
          final text = match.group(1)?.trim();
          if (text != null && text.isNotEmpty) {
            if (buffer.isNotEmpty) buffer.writeln();
            buffer.write(text);
          }
        }
        final slideText = buffer.toString().trim();
        if (slideText.isNotEmpty) {
          slides.add(slideText);
        }
      }
      return slides;
    } catch (_) {
      return [];
    }
  }

  static String extract(Uint8List bytes) {
    return extractSlides(bytes).join('\n\n');
  }
}
