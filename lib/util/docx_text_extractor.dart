import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart' as xml;

class DocxTextExtractor {
  DocxTextExtractor._();

  static String extract(Uint8List bytes) {
    try {
      final archive = ZipDecoder().decodeBytes(bytes);
      final buffer = StringBuffer();

      for (final file in archive) {
        if (!file.isFile || file.name != 'word/document.xml') continue;

        final document = xml.XmlDocument.parse(utf8.decode(file.content));
        for (final paragraph in document.findAllElements('w:p')) {
          final text = paragraph
              .findAllElements('w:t')
              .map((node) => node.innerText)
              .join();
          if (text.isNotEmpty) {
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
