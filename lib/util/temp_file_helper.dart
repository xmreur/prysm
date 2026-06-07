import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

class TempFileHelper {
  TempFileHelper._();

  static const _uuid = Uuid();

  static Future<String> write(Uint8List bytes, String fileName) async {
    final dir = await getTemporaryDirectory();
    final ext = p.extension(fileName);
    final uniqueName = '${_uuid.v4()}${ext.isNotEmpty ? ext : '.bin'}';
    final file = File(p.join(dir.path, uniqueName));
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }
}
