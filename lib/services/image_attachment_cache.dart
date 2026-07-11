import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:prysm/util/logging.dart';

class CachedImage {
  final Uint8List bytes;
  final String mimeType;
  final int width;
  final int height;

  const CachedImage({
    required this.bytes,
    required this.mimeType,
    required this.width,
    required this.height,
  });

  double get aspectRatio =>
      height > 0 ? width / height : 1.0;
}

class ImageAttachmentCache {
  ImageAttachmentCache._();

  static const _maxMemoryEntries = 30;
  static final _memory = <String, CachedImage>{};
  static final _memoryOrder = <String>[];
  static final _inflight = <String, Future<CachedImage>>{};
  static String? _diskDir;

  static Future<CachedImage> resolve({
    required String messageId,
    required Future<Uint8List> Function() decrypt,
    Uint8List? inlineBytes,
    void Function(double progress)? onProgress,
  }) async {
    if (inlineBytes != null && inlineBytes.isNotEmpty) {
      onProgress?.call(1.0);
      return _fromBytes(inlineBytes);
    }

    final mem = _memory[messageId];
    if (mem != null) {
      _touchMemory(messageId);
      onProgress?.call(1.0);
      return mem;
    }

    final disk = await _readDisk(messageId);
    if (disk != null) {
      _putMemory(messageId, disk);
      onProgress?.call(1.0);
      return disk;
    }

    final existing = _inflight[messageId];
    if (existing != null) return existing;

    onProgress?.call(0.1);
    final future = _resolveUncached(messageId: messageId, decrypt: decrypt, onProgress: onProgress);
    _inflight[messageId] = future;
    try {
      return await future;
    } finally {
      _inflight.remove(messageId);
    }
  }

  static Future<CachedImage> _resolveUncached({
    required String messageId,
    required Future<Uint8List> Function() decrypt,
    void Function(double progress)? onProgress,
  }) async {
    onProgress?.call(0.2);
    final bytes = await decrypt();
    onProgress?.call(0.6);
    if (bytes.isEmpty) {
      throw StateError('Empty image payload for $messageId');
    }
    final cached = await _fromBytes(bytes);
    onProgress?.call(0.8);
    _putMemory(messageId, cached);
    await _writeDisk(messageId, bytes);
    onProgress?.call(1.0);
    return cached;
  }

  static Future<CachedImage> _fromBytes(Uint8List bytes) async {
    final mimeType = sniffImageMimeType(bytes);
    final dims = await _decodeDimensions(bytes);
    return CachedImage(
      bytes: bytes,
      mimeType: mimeType,
      width: dims.$1,
      height: dims.$2,
    );
  }

  static Future<(int, int)> _decodeDimensions(Uint8List bytes) async {
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final w = frame.image.width;
      final h = frame.image.height;
      frame.image.dispose();
      codec.dispose();
      return (w, h);
    } catch (_) {
      return (4, 3);
    }
  }

  static String sniffImageMimeType(Uint8List bytes) {
    if (bytes.length >= 3 &&
        bytes[0] == 0xFF &&
        bytes[1] == 0xD8 &&
        bytes[2] == 0xFF) {
      return 'image/jpeg';
    }
    if (bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      return 'image/png';
    }
    if (bytes.length >= 12 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return 'image/webp';
    }
    if (bytes.length >= 6 &&
        bytes[0] == 0x47 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46) {
      return 'image/gif';
    }
    return 'image/jpeg';
  }

  static void _putMemory(String messageId, CachedImage image) {
    if (_memory.containsKey(messageId)) {
      _memoryOrder.remove(messageId);
    } else if (_memory.length >= _maxMemoryEntries && _memoryOrder.isNotEmpty) {
      final evict = _memoryOrder.removeAt(0);
      _memory.remove(evict);
    }
    _memory[messageId] = image;
    _memoryOrder.add(messageId);
  }

  static void _touchMemory(String messageId) {
    _memoryOrder.remove(messageId);
    _memoryOrder.add(messageId);
  }

  static Future<String> _cacheDir() async {
    if (_diskDir != null) return _diskDir!;
    final temp = await getTemporaryDirectory();
    final dir = Directory('${temp.path}/img_cache');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _diskDir = dir.path;
    return _diskDir!;
  }

  static String _diskPath(String messageId, String dir) =>
      '$dir/$messageId.img';

  static Future<void> _writeDisk(String messageId, Uint8List bytes) async {
    try {
      final dir = await _cacheDir();
      await File(_diskPath(messageId, dir)).writeAsBytes(bytes, flush: true);
    } catch (e) {
      Logging.error('Image disk cache write failed ($messageId): $e', 'ImageAttachmentCache');
    }
  }

  static Future<CachedImage?> _readDisk(String messageId) async {
    try {
      final dir = await _cacheDir();
      final file = File(_diskPath(messageId, dir));
      if (!await file.exists()) return null;
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) return null;
      return _fromBytes(bytes);
    } catch (e) {
      Logging.error('Image disk cache read failed ($messageId): $e', 'ImageAttachmentCache');
      return null;
    }
  }

  static Future<void> invalidate(String messageId) async {
    _memory.remove(messageId);
    _memoryOrder.remove(messageId);
    _inflight.remove(messageId);
    try {
      final dir = await _cacheDir();
      final file = File(_diskPath(messageId, dir));
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {}
  }

  @visibleForTesting
  static void resetForTest() {
    _memory.clear();
    _memoryOrder.clear();
    _inflight.clear();
    _diskDir = null;
  }

  @visibleForTesting
  static void setDiskDirForTest(String? path) {
    _diskDir = path;
  }

  @visibleForTesting
  static int memoryEntryCount() => _memory.length;

  @visibleForTesting
  static int inflightCount() => _inflight.length;
}
