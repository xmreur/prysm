import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:prysm/services/image_attachment_cache.dart';
import 'package:prysm/util/download_location.dart';

/// A file in the user downloads folder surfaced by the storage manager.
class DownloadedFileEntry {
  final String name;
  final String path;
  final int bytes;
  final DateTime modifiedAt;

  const DownloadedFileEntry({
    required this.name,
    required this.path,
    required this.bytes,
    required this.modifiedAt,
  });
}

/// Disk usage broken down by storage category.
class StorageUsageBreakdown {
  final int messagesDatabaseBytes;
  final int messageBlobsBytes;
  final int imageCacheBytes;
  final int voiceCacheBytes;
  final int downloadsBytes;
  final int otherAppDataBytes;

  const StorageUsageBreakdown({
    required this.messagesDatabaseBytes,
    required this.messageBlobsBytes,
    required this.imageCacheBytes,
    required this.voiceCacheBytes,
    required this.downloadsBytes,
    required this.otherAppDataBytes,
  });

  int get cacheBytes => imageCacheBytes + voiceCacheBytes;

  int get chatMediaBytes => messagesDatabaseBytes + messageBlobsBytes;

  int get totalBytes =>
      messagesDatabaseBytes +
      messageBlobsBytes +
      imageCacheBytes +
      voiceCacheBytes +
      downloadsBytes +
      otherAppDataBytes;
}

/// Computes on-disk usage and manages ephemeral caches.
class StorageUsageService {
  StorageUsageService._();

  static final _voiceCachePattern = RegExp(
    r'(?:voice_cache_|group_voice_cache_|direct_voice_|group_voice_).+\.wav$',
  );

  static Future<StorageUsageBreakdown> compute() async {
    final docDir = await getApplicationDocumentsDirectory();
    final tempDir = await getTemporaryDirectory();
    final prysmDir = Directory(p.join(docDir.path, 'prysm'));
    final blobsDir = Directory(p.join(docDir.path, 'message_blobs'));
    final imgCacheDir = Directory(p.join(tempDir.path, 'img_cache'));

    final results = await Future.wait([
      _messagesDatabaseBytes(prysmDir),
      _directorySize(blobsDir),
      _directorySize(imgCacheDir),
      _voiceCacheBytes(tempDir),
      _downloadsBytes(),
      _otherAppDataBytes(prysmDir, docDir.path),
    ]);

    return StorageUsageBreakdown(
      messagesDatabaseBytes: results[0],
      messageBlobsBytes: results[1],
      imageCacheBytes: results[2],
      voiceCacheBytes: results[3],
      downloadsBytes: results[4],
      otherAppDataBytes: results[5],
    );
  }

  static Future<void> clearEphemeralCaches() async {
    await ImageAttachmentCache.clearAll();
    final tempDir = await getTemporaryDirectory();
    await _deleteVoiceCacheFiles(tempDir);
  }

  static Future<List<DownloadedFileEntry>> listDownloadedFiles() async {
    final dir = await DownloadLocation.resolveDirectory();
    if (dir == null || !await dir.exists()) return [];

    final entries = <DownloadedFileEntry>[];
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! File) continue;
      if (entity.path.endsWith('.prysmbackup')) continue;
      final stat = await entity.stat();
      entries.add(
        DownloadedFileEntry(
          name: p.basename(entity.path),
          path: entity.path,
          bytes: stat.size,
          modifiedAt: stat.modified,
        ),
      );
    }
    entries.sort((a, b) => b.bytes.compareTo(a.bytes));
    return entries;
  }

  static Future<int> _messagesDatabaseBytes(Directory prysmDir) async {
    if (!await prysmDir.exists()) return 0;
    var total = 0;
    for (final name in ['messages.db', 'messages.db-wal', 'messages.db-shm']) {
      final file = File(p.join(prysmDir.path, name));
      if (await file.exists()) {
        total += await file.length();
      }
    }
    return total;
  }

  static Future<int> _otherAppDataBytes(
    Directory prysmDir,
    String docPath,
  ) async {
    var total = 0;

    if (await prysmDir.exists()) {
      await for (final entity in prysmDir.list(recursive: true)) {
        if (entity is! File) continue;
        final base = p.basename(entity.path);
        if (base == 'messages.db' ||
            base == 'messages.db-wal' ||
            base == 'messages.db-shm') {
          continue;
        }
        total += await entity.length();
      }
    }

    final legacyBackups = Directory(p.join(docPath, 'prysm_backups'));
    if (await legacyBackups.exists()) {
      total += await _directorySize(legacyBackups);
    }

    return total;
  }

  static Future<int> _downloadsBytes() async {
    final dir = await DownloadLocation.resolveDirectory();
    if (dir == null || !await dir.exists()) return 0;

    var total = 0;
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is File && !entity.path.endsWith('.prysmbackup')) {
        total += await entity.length();
      }
    }
    return total;
  }

  static Future<int> _directorySize(Directory dir) async {
    if (!await dir.exists()) return 0;
    var total = 0;
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is File) {
        total += await entity.length();
      }
    }
    return total;
  }

  @visibleForTesting
  static Future<int> directorySizeForTest(Directory dir) => _directorySize(dir);

  static Future<int> _voiceCacheBytes(Directory tempDir) async {
    if (!await tempDir.exists()) return 0;
    var total = 0;
    await for (final entity in tempDir.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      if (_voiceCachePattern.hasMatch(name)) {
        total += await entity.length();
      }
    }
    return total;
  }

  static Future<void> _deleteVoiceCacheFiles(Directory tempDir) async {
    if (!await tempDir.exists()) return;
    await for (final entity in tempDir.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      if (_voiceCachePattern.hasMatch(name)) {
        try {
          await entity.delete();
        } catch (_) {}
      }
    }
  }
}
