import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:prysm/database/messages.dart';
import 'package:prysm/models/chat/prysm_message.dart';
import 'package:prysm/crypto/wire.dart';
import 'package:prysm/util/key_manager.dart';

class FileAttachmentResolver {
  FileAttachmentResolver._();

  static const _maxCacheEntries = 20;
  static final _cache = <String, Uint8List>{};
  static final _cacheOrder = <String>[];

  static Future<Uint8List> resolve(
    FileMessage message, {
    KeyManager? keyManager,
    void Function(double progress)? onProgress,
  }) async {
    final cached = _cache[message.id];
    if (cached != null) {
      onProgress?.call(1.0);
      return cached;
    }

    onProgress?.call(0.1);
    final bytes = await _resolveUncached(message, keyManager: keyManager);
    onProgress?.call(0.7);
    _putCache(message.id, bytes);
    onProgress?.call(1.0);
    return bytes;
  }

  static Future<Uint8List> _resolveUncached(
    FileMessage message, {
    KeyManager? keyManager,
  }) async {
    var source = message.source;
    if (source.isEmpty) {
      final wire = await MessagesDb.getMessageWire(message.id);
      if (wire != null && wire.isNotEmpty) {
        source = wire;
      }
    }
    if (source.isEmpty) {
      return Uint8List(0);
    }

    if (source.startsWith('audio:')) {
      return Uint8List(0);
    }

    if (_looksLikeBase64Payload(source)) {
      try {
        return base64Decode(source);
      } catch (_) {
        // Fall through to decrypt path.
      }
    }

    if (keyManager == null) {
      try {
        return base64Decode(source);
      } catch (_) {
        return Uint8List(0);
      }
    }

    return decryptEncryptedSource(source, keyManager);
  }

  static bool _looksLikeBase64Payload(String source) {
    if (source.startsWith('{')) return false;
    if (source.startsWith('data:')) {
      final comma = source.indexOf(',');
      if (comma < 0) return false;
      return _isMostlyBase64(source.substring(comma + 1));
    }
    return _isMostlyBase64(source);
  }

  static bool _isMostlyBase64(String value) {
    if (value.length < 16) return false;
    final sample = value.length > 256 ? value.substring(0, 256) : value;
    return RegExp(r'^[A-Za-z0-9+/=\s]+$').hasMatch(sample);
  }

  static Future<Uint8List> decryptEncryptedSource(
    String encryptedJson,
    KeyManager keyManager,
  ) async {
    return CryptoWire.decryptFile(encryptedJson, keyManager.identity);
  }

  static void _putCache(String messageId, Uint8List bytes) {
    if (_cache.containsKey(messageId)) {
      _cacheOrder.remove(messageId);
    } else if (_cache.length >= _maxCacheEntries && _cacheOrder.isNotEmpty) {
      final evict = _cacheOrder.removeAt(0);
      _cache.remove(evict);
    }
    _cache[messageId] = bytes;
    _cacheOrder.add(messageId);
  }

  static void invalidate(String messageId) {
    _cache.remove(messageId);
    _cacheOrder.remove(messageId);
  }
}
