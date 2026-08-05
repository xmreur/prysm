import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Stores oversized message payloads on disk instead of in SQLite rows.
class MessageBlobStore {
  MessageBlobStore._();

  /// Payloads larger than this are stored in the app documents directory.
  static const int inlineThreshold = 512 * 1024;

  static const String markerPrefix = 'blob:';

  static bool isMarker(String? wire) =>
      wire != null && wire.startsWith(markerPrefix);

  static String? storageIdFromMarker(String? wire) {
    if (!isMarker(wire)) return null;
    return wire!.substring(markerPrefix.length);
  }

  static String marker(String storageId) => '$markerPrefix$storageId';

  static final RegExp _safeStorageId =
      RegExp(r'^[A-Za-z0-9._:-]+$');

  /// Rejects storage ids that could escape `message_blobs/` when used as a
  /// file name. Legitimate ids are wire ids (uuid-like, hex, `-`, `_`, `.`)
  /// optionally prefixed `<groupId>::`; anything else (separators, traversal
  /// sequences, control characters) is refused before it reaches `File`.
  static void _validateStorageId(String storageId) {
    if (storageId.isEmpty ||
        storageId == '.' ||
        storageId == '..' ||
        !_safeStorageId.hasMatch(storageId)) {
      throw ArgumentError.value(storageId, 'storageId', 'unsafe blob id');
    }
  }

  static Future<File> _fileFor(String storageId) async {
    _validateStorageId(storageId);
    final dir = await getApplicationDocumentsDirectory();
    final folder = Directory(p.join(dir.path, 'message_blobs'));
    if (!await folder.exists()) {
      await folder.create(recursive: true);
    }
    return File(p.join(folder.path, storageId));
  }

  static Future<bool> exists(String storageId) async {
    try {
      return (await _fileFor(storageId)).exists();
    } on ArgumentError {
      return false;
    }
  }

  static Future<void> save(String storageId, String content) async {
    final file = await _fileFor(storageId);
    await file.writeAsString(content, flush: true);
  }

  static Future<String> read(String storageId) async {
    return (await _fileFor(storageId)).readAsString();
  }

  static Future<void> delete(String storageId) async {
    try {
      final file = await _fileFor(storageId);
      if (await file.exists()) {
        await file.delete();
      }
    } on ArgumentError {
      // Unsafe id: refuse to touch the filesystem rather than resolve it.
    }
  }

  /// Offloads [wire] to disk when it exceeds [inlineThreshold].
  static Future<String?> prepareForStorage(String storageId, String? wire) async {
    if (wire == null || wire.isEmpty || isMarker(wire)) return wire;
    if (wire.length <= inlineThreshold) return wire;
    await save(storageId, wire);
    return marker(storageId);
  }

  /// Resolves a DB [wire] value to the full payload.
  static Future<String?> resolve(String? wire) async {
    if (wire == null || wire.isEmpty) return wire;
    final storageId = storageIdFromMarker(wire);
    if (storageId == null) return wire;
    if (!await exists(storageId)) return null;
    return read(storageId);
  }
}
