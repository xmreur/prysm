import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:opus_dart/opus_dart.dart';
import 'package:opus_flutter/opus_flutter.dart' as opus_flutter;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:prysm/util/logging.dart';

class OpusCodec {
  OpusCodec._({
    required SimpleOpusEncoder encoder,
    required SimpleOpusDecoder decoder,
    required this.sampleRate,
    required this.channels,
    required this.frameSamples,
  })  : _encoder = encoder,
        _decoder = decoder;

  final SimpleOpusEncoder _encoder;
  final SimpleOpusDecoder _decoder;
  final int sampleRate;
  final int channels;
  final int frameSamples;

  static bool _loaded = false;
  static bool _available = false;
  static String? lastLoadError;

  static bool get isAvailable => _available;

  static Future<bool> ensureLoaded() async {
    if (_loaded) return _available;
    lastLoadError = null;
    try {
      final lib = await _loadLibrary();
      initOpus(lib);
      _available = true;
    } catch (e, stack) {
      _available = false;
      lastLoadError = e.toString();
      if (kDebugMode) {
        Logging.error('failed to load libopus: $e\n$stack', 'OpusCodec');
      }
    }
    _loaded = true;
    return _available;
  }

  static const _opusDownloadUrl =
      'https://github.com/xmreur/prysm-resources/raw/refs/heads/main/tor/exec/macos/libopus.dylib';

  static Future<dynamic> _loadLibrary() async {
    if (kIsWeb) {
      return opus_flutter.load();
    }
    if (Platform.isLinux) {
      return _openFirst(const [
        'libopus.so.0',
        'libopus.so',
        '/usr/lib/libopus.so.0',
        '/usr/lib64/libopus.so.0',
      ]);
    }
    if (Platform.isMacOS) {
      final bundled = await _ensureMacOsOpus();
      return _openFirst([
        bundled,
        'libopus.dylib',
        'libopus.0.dylib',
        '/opt/homebrew/lib/libopus.dylib',
        '/usr/local/lib/libopus.dylib',
      ]);
    }
    return opus_flutter.load();
  }

  static Future<String> _ensureMacOsOpus() async {
    final dir = await getApplicationDocumentsDirectory();
    final libDir = Directory(p.join(dir.path, 'prysm', 'native_libs'));
    if (!libDir.existsSync()) {
      libDir.createSync(recursive: true);
    }
    final dylibPath = p.join(libDir.path, 'libopus.dylib');
    if (!File(dylibPath).existsSync()) {
      Logging.debug('Downloading libopus.dylib ...', 'OpusCodec');
      final resp = await http.get(Uri.parse(_opusDownloadUrl));
      if (resp.statusCode != 200) {
        throw StateError('Failed to download libopus.dylib: ${resp.statusCode}');
      }
      await File(dylibPath).writeAsBytes(resp.bodyBytes);
    }
    return dylibPath;
  }

  static DynamicLibrary _openFirst(List<String> names) {
    Object? lastError;
    for (final name in names) {
      try {
        return DynamicLibrary.open(name);
      } catch (e) {
        lastError = e;
      }
    }
    throw StateError(
      'Could not load libopus (tried ${names.join(', ')}): $lastError',
    );
  }

  static Future<OpusCodec?> create({
    int sampleRate = 16000,
    int channels = 1,
    int frameDurationMs = 20,
  }) async {
    if (!await ensureLoaded()) return null;
    final frameSamples = sampleRate * frameDurationMs ~/ 1000;
    try {
      final encoder = SimpleOpusEncoder(
        sampleRate: sampleRate,
        channels: channels,
        application: Application.voip,
      );
      final decoder = SimpleOpusDecoder(
        sampleRate: sampleRate,
        channels: channels,
      );
      return OpusCodec._(
        encoder: encoder,
        decoder: decoder,
        sampleRate: sampleRate,
        channels: channels,
        frameSamples: frameSamples,
      );
    } catch (e, stack) {
      lastLoadError = e.toString();
      if (kDebugMode) {
        Logging.error('encoder/decoder init failed: $e\n$stack', 'OpusCodec');
      }
      return null;
    }
  }

  Uint8List encodeFrame(Int16List pcm) {
    return _encoder.encode(input: pcm);
  }

  Int16List decodeFrame(Uint8List opusBytes) {
    return _decoder.decode(input: opusBytes);
  }

  void dispose() {
    if (!_encoder.destroyed) {
      _encoder.destroy();
    }
    if (!_decoder.destroyed) {
      _decoder.destroy();
    }
  }
}
