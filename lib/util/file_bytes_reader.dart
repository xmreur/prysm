import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

/// Reads a file off the UI isolate so large picks do not freeze the app.
Future<Uint8List> readFileBytesDeferred(String path) {
  return Isolate.run(() => File(path).readAsBytesSync());
}

Future<int> fileSizeDeferred(String path) {
  return Isolate.run(() => File(path).lengthSync());
}
