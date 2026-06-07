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

  /// Backup files in the active download folder, plus any in the legacy app dir.
  static Future<List<File>> listBackupFiles() async {
    final files = <String, File>{};

    final downloadDir = await resolveDirectory();
    if (downloadDir != null) {
      await for (final entity in downloadDir.list()) {
        if (entity is File && entity.path.endsWith('.prysmbackup')) {
          files[entity.path] = entity;
        }
      }
    }

    final docDir = await getApplicationDocumentsDirectory();
    final legacyDir = Directory(p.join(docDir.path, 'prysm_backups'));
    if (await legacyDir.exists()) {
      await for (final entity in legacyDir.list()) {
        if (entity is File && entity.path.endsWith('.prysmbackup')) {
          files[entity.path] = entity;
        }
      }
    }

    final list = files.values.toList();
    list.sort((a, b) => b.path.compareTo(a.path));
    return list;
  }
}
