import 'dart:io';
import 'dart:typed_data';

import 'package:open_file/open_file.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class PdfSystemOpen {
  PdfSystemOpen._();

  static Future<String?> open(Uint8List bytes, String fileName) async {
    final dir = await getTemporaryDirectory();
    final safeName = p.basename(fileName);
    final file = File(p.join(dir.path, safeName));
    await file.writeAsBytes(bytes, flush: true);
    final result = await OpenFile.open(file.path);
    return result.message;
  }
}
