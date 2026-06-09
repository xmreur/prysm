import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/painting.dart';

/// Stable [MemoryImage] instances for contact avatars (avoids flicker on rebuild).
class AvatarImageCache {
  AvatarImageCache._();

  static const _maxEntries = 64;
  static final _images = <String, MemoryImage>{};
  static final _order = <String>[];

  static MemoryImage? imageForBase64(String? base64) {
    if (base64 == null || base64.isEmpty) return null;

    final cached = _images[base64];
    if (cached != null) {
      _touch(base64);
      return cached;
    }

    try {
      final bytes = base64Decode(base64);
      final image = MemoryImage(Uint8List.fromList(bytes));
      _put(base64, image);
      return image;
    } catch (_) {
      return null;
    }
  }

  static void _put(String key, MemoryImage image) {
    if (_images.containsKey(key)) {
      _order.remove(key);
    } else if (_images.length >= _maxEntries && _order.isNotEmpty) {
      final evict = _order.removeAt(0);
      _images.remove(evict);
    }
    _images[key] = image;
    _order.add(key);
  }

  static void _touch(String key) {
    _order.remove(key);
    _order.add(key);
  }
}
