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

  /// Reduces a peer-supplied file name to a safe basename that cannot escape
  /// the download directory: strips directory components, replaces reserved
  /// characters, rejects traversal sequences, and caps the length at 200
  /// chars (extension preserved).
  static String sanitizeFileName(String fileName) {
    var name = p.posix.basename(fileName.replaceAll(r'\', '/'));
    final sanitized = StringBuffer();
    for (final codeUnit in name.codeUnits) {
      final ch = String.fromCharCode(codeUnit);
      if (codeUnit < 0x20 || '<>:"|?*'.contains(ch)) {
        sanitized.write('_');
      } else {
        sanitized.write(ch);
      }
    }
    name = sanitized.toString();
    if (name.isEmpty || name == '.' || name == '..') {
      return 'download';
    }
    final originalExt = p.extension(name);
    var ext = originalExt;
    if (ext.length > 20) {
      ext = ext.substring(0, _safeCut(ext, 20));
    }
    if (name.length > 200) {
      final stem = name.substring(0, name.length - originalExt.length);
      final keep = 200 - ext.length;
      name =
          (stem.length <= keep ? stem : stem.substring(0, _safeCut(stem, keep))) +
              ext;
    }
    return name;
  }

  /// Adjusts a UTF-16 cut point so [value].substring(0, cut) never splits a
  /// surrogate pair: if the last code unit at the boundary is a high
  /// surrogate, its low-surrogate partner was just cut away, so back up one
  /// code unit and drop the pair whole. A lone surrogate is mangled by
  /// filesystems, so a truncation must never emit one.
  static int _safeCut(String value, int cut) {
    if (cut > 0 &&
        cut < value.length &&
        value.codeUnitAt(cut - 1) >= 0xd800 &&
        value.codeUnitAt(cut - 1) <= 0xdbff) {
      return cut - 1;
    }
    return cut;
  }

  /// Pick a unique filename inside the download directory.
  static Future<File> uniqueFile(String fileName) async {
    final dir = await resolveDirectory();
    if (dir == null) {
      throw StateError('Downloads folder not available');
    }
    final safeName = sanitizeFileName(fileName);
    var file = File(p.join(dir.path, safeName));
    var c = 0;
    while (await file.exists()) {
      file = File(p.join(dir.path, '$safeName - $c'));
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
