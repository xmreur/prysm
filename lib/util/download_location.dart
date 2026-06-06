import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:prysm/services/settings_service.dart';

/// Resolves where chat file downloads are saved.
class DownloadLocation {
  DownloadLocation._();

  static Future<Directory?> defaultDirectory() async {
    if (Platform.isAndroid) {
      final dir = Directory('/storage/emulated/0/Download');
      if (await dir.exists()) return dir;
    }
    return getDownloadsDirectory();
  }

  /// Active download folder (custom path or system default).
  static Future<Directory?> resolveDirectory() async {
    final custom = SettingsService().customDownloadPath;
    if (custom != null && custom.isNotEmpty) {
      final dir = Directory(custom);
      if (await dir.exists()) {
        return dir;
      }
    }
    return defaultDirectory();
  }

  /// Human-readable path for settings UI.
  static Future<String> displayPath() async {
    final custom = SettingsService().customDownloadPath;
    if (custom != null && custom.isNotEmpty) {
      return custom;
    }
    final dir = await defaultDirectory();
    if (dir != null) {
      return '${dir.path} (system default)';
    }
    return 'System default (unavailable)';
  }

  static Future<bool> isUsingCustomPath() async {
    final custom = SettingsService().customDownloadPath;
    return custom != null && custom.isNotEmpty;
  }

  /// Pick a unique filename inside the download directory.
  static Future<File> uniqueFile(String fileName) async {
    final dir = await resolveDirectory();
    if (dir == null) {
      throw StateError('Downloads folder not available');
    }
    var file = File(p.join(dir.path, fileName));
    var c = 0;
    while (await file.exists()) {
      file = File(p.join(dir.path, '$fileName - $c'));
      c++;
    }
    return file;
  }

  static Future<File> saveBytes(Uint8List bytes, String fileName) async {
    final file = await uniqueFile(fileName);
    await file.writeAsBytes(bytes);
    return file;
  }
}
