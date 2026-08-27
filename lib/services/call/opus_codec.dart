import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:opus_dart/opus_dart.dart';
import 'package:opus_flutter/opus_flutter.dart' as opus_flutter;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:prysm/client/TorHttpClient.dart';
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

  static const _torProxyHost = '127.0.0.1';
  static const _torProxyPort = 9050;

  static const _opusDownloadUrl =
      'https://github.com/xmreur/prysm-resources/raw/refs/heads/main/tor/exec/macos/libopus.dylib';
  static const String _opusSha256 =
      '435581a316f3dd41982f3101caa6be6ec974572e31765cd0e29c7cbe30198609';
  static const int _opusSizeBytes = 357824;
  static const int _maxOpusBytes = 4 * 1024 * 1024;
  static const Duration _downloadTimeout = Duration(seconds: 120);

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
      String? bundled;
      try {
        bundled = await _ensureMacOsOpus();
      } catch (_) {
        // A failed or unverifiable download contributes no candidate; the
        // system paths below are still tried so opus degrades instead of
        // failing the whole list.
      }
      return _openFirst([
        ?bundled,
        'libopus.dylib',
        'libopus.0.dylib',
        '/opt/homebrew/lib/libopus.dylib',
        '/usr/local/lib/libopus.dylib',
      ]);
    }
    return opus_flutter.load();
  }

  /// The pinned sha256 of the trusted macOS libopus artifact, exported so
  /// tests can assert on the trust decision's constant without reading this
  /// source file.
  @visibleForTesting
  static String get pinnedOpusSha256 => _opusSha256;

  /// The pinned size in bytes of the trusted macOS libopus artifact.
  @visibleForTesting
  static int get pinnedOpusSizeBytes => _opusSizeBytes;

  /// True iff [bytes] is exactly the pinned libopus artifact for macOS:
  /// length check first (cheap reject), then sha256 against [_opusSha256].
  /// Used by both the cache-verification path and the post-download path.
  @visibleForTesting
  static bool isTrustedOpusPayload(List<int> bytes) {
    if (bytes.length != _opusSizeBytes) return false;
    return sha256.convert(bytes).toString() == _opusSha256;
  }

  static Future<String> _ensureMacOsOpus() async {
    final dir = await getApplicationDocumentsDirectory();
    final libDir = Directory(p.join(dir.path, 'prysm', 'native_libs'));
    if (!libDir.existsSync()) {
      libDir.createSync(recursive: true);
    }
    final dylibPath = p.join(libDir.path, 'libopus.dylib');

    final cachedFile = File(dylibPath);
    if (cachedFile.existsSync()) {
      // Reject a wrong-sized cache by stat before any byte enters memory: a
      // locally-poisoned oversized cache must not force a full in-memory read
      // on every load. The length check is the same cheap reject
      // isTrustedOpusPayload performs first.
      final cachedBytes = cachedFile.lengthSync() == _opusSizeBytes
          ? cachedFile.readAsBytesSync()
          : null;
      if (cachedBytes != null && isTrustedOpusPayload(cachedBytes)) {
        return dylibPath;
      }
      Logging.error(
        'Cached libopus.dylib failed integrity check; removing and '
        're-downloading over Tor',
        'OpusCodec',
      );
      cachedFile.deleteSync();
    }

    Logging.debug('Downloading libopus.dylib over Tor ...', 'OpusCodec');
    final bytes = await _downloadMacOsOpus();
    if (!isTrustedOpusPayload(bytes)) {
      throw StateError(
        'Downloaded libopus.dylib failed integrity check: '
        '${bytes.length} bytes, sha256 ${sha256.convert(bytes)} '
        '(expected $_opusSizeBytes bytes, sha256 $_opusSha256)',
      );
    }

    final partFile = File('$dylibPath.part');
    await partFile.writeAsBytes(bytes, flush: true);
    await partFile.rename(dylibPath);
    return dylibPath;
  }

  static Future<Uint8List> _downloadMacOsOpus() async {
    final torClient = TorHttpClient(
      proxyHost: _torProxyHost,
      proxyPort: _torProxyPort,
    );
    try {
      final response = await torClient
          .get(Uri.parse(_opusDownloadUrl), const {
            'Accept': 'application/octet-stream',
          })
          .timeout(_downloadTimeout);

      if (response.statusCode < 200 || response.statusCode >= 400) {
        throw StateError(
          'Failed to download libopus.dylib: ${response.statusCode}',
        );
      }

      final builder = BytesBuilder(copy: false);
      var received = 0;
      // dart:io applies no read timeout to an active response body, so a
      // stalled Tor exit would hang this loop (and with it call setup)
      // forever. Bound the whole body phase by the same [_downloadTimeout]
      // used for the header phase: every chunk wait races a shrinking
      // remaining-time timeout, so even a slow trickle cannot outrun the
      // deadline. A timeout fails the download cleanly (nothing is written
      // and opus degrades to the system libraries), like every other
      // failure mode.
      final deadline = DateTime.now().add(_downloadTimeout);
      final chunks = StreamIterator(response);
      try {
        while (true) {
          var remaining = deadline.difference(DateTime.now());
          if (remaining.isNegative) remaining = Duration.zero;
          if (!await chunks.moveNext().timeout(
                remaining,
                onTimeout: () => throw TimeoutException(
                  'Downloading libopus.dylib exceeded '
                  '${_downloadTimeout.inSeconds}s',
                  _downloadTimeout,
                ),
              )) {
            break;
          }
          final chunk = chunks.current;
          received += chunk.length;
          if (received > _maxOpusBytes) {
            throw StateError(
              'Downloaded libopus.dylib exceeds $_maxOpusBytes bytes',
            );
          }
          builder.add(chunk);
        }
      } finally {
        // Abandoning the iterator mid-body would leave the response stream
        // subscribed (and its Tor connection open); cancel so close() can
        // tear the client down.
        await chunks.cancel();
      }
      return builder.takeBytes();
    } finally {
      await torClient.close();
    }
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

/// Independent Opus decoder for one group-call remote stream.
class OpusStreamDecoder {
  OpusStreamDecoder._(this._decoder, this.sampleRate, this.channels);

  final SimpleOpusDecoder _decoder;
  final int sampleRate;
  final int channels;

  static Future<OpusStreamDecoder?> create({
    int sampleRate = 16000,
    int channels = 1,
  }) async {
    if (!await OpusCodec.ensureLoaded()) return null;
    try {
      return OpusStreamDecoder._(
        SimpleOpusDecoder(sampleRate: sampleRate, channels: channels),
        sampleRate,
        channels,
      );
    } catch (e) {
      if (kDebugMode) {
        Logging.error('decoder init failed: $e', 'OpusStreamDecoder');
      }
      return null;
    }
  }

  Int16List decodeFrame(Uint8List opusBytes) {
    return _decoder.decode(input: opusBytes);
  }

  void dispose() {
    if (!_decoder.destroyed) {
      _decoder.destroy();
    }
  }
}
