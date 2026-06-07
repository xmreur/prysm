import 'dart:convert';
import 'dart:typed_data';

import 'package:prysm/client/TorHttpClient.dart';
import 'package:prysm/models/link_preview.dart';
import 'package:prysm/util/link_unfurl_parser.dart';
import 'package:prysm/util/link_unfurl_policy.dart';

class LinkUnfurlService {
  LinkUnfurlService._();
  static final LinkUnfurlService instance = LinkUnfurlService._();

  static const _torProxyHost = '127.0.0.1';
  static const _torProxyPort = 9050;

  final _cache = <String, LinkPreview?>{};
  final _imageCache = <String, Uint8List?>{};
  final _inFlight = <String, Future<LinkPreview?>>{};
  final _imageInFlight = <String, Future<Uint8List?>>{};

  Future<LinkPreview?> fetch(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !LinkUnfurlPolicy.isSafeToUnfurl(uri)) return null;

    if (_cache.containsKey(url)) return _cache[url];

    final pending = _inFlight[url];
    if (pending != null) return pending;

    final future = _fetchUncached(uri, url);
    _inFlight[url] = future;
    try {
      final preview = await future;
      _remember(url, preview);
      return preview;
    } finally {
      _inFlight.remove(url);
    }
  }

  Future<Uint8List?> fetchImage(String imageUrl) async {
    final uri = Uri.tryParse(imageUrl);
    if (uri == null || !LinkUnfurlPolicy.isSafeToUnfurl(uri)) return null;

    if (_imageCache.containsKey(imageUrl)) return _imageCache[imageUrl];

    final pending = _imageInFlight[imageUrl];
    if (pending != null) return pending;

    final future = _fetchImageUncached(uri);
    _imageInFlight[imageUrl] = future;
    try {
      final bytes = await future;
      _rememberImage(imageUrl, bytes);
      return bytes;
    } finally {
      _imageInFlight.remove(imageUrl);
    }
  }

  Future<LinkPreview?> _fetchUncached(Uri uri, String originalUrl) async {
    final torClient = TorHttpClient(
      proxyHost: _torProxyHost,
      proxyPort: _torProxyPort,
    );
    try {
      final response = await torClient
          .get(uri, const {
            'User-Agent': 'Prysm/1.0 (link preview)',
            'Accept': 'text/html,application/xhtml+xml',
          })
          .timeout(LinkUnfurlPolicy.fetchTimeout);

      if (response.statusCode < 200 || response.statusCode >= 400) {
        return null;
      }

      final body = await _readLimited(response, LinkUnfurlPolicy.maxHtmlBytes);
      final html = utf8.decode(body, allowMalformed: true);
      final headEnd = html.indexOf('</head>');
      final snippet = headEnd > 0 ? html.substring(0, headEnd) : html;
      final parsed = LinkUnfurlParser.parse(originalUrl, snippet);
      if (parsed == null) return null;

      final imageUrl = LinkUnfurlPolicy.resolveUrl(uri, parsed.imageUrl);
      return LinkPreview(
        url: parsed.url,
        title: parsed.title,
        description: parsed.description,
        imageUrl: imageUrl,
        siteName: parsed.siteName,
      );
    } catch (_) {
      return null;
    } finally {
      torClient.close();
    }
  }

  Future<Uint8List?> _fetchImageUncached(Uri uri) async {
    final torClient = TorHttpClient(
      proxyHost: _torProxyHost,
      proxyPort: _torProxyPort,
    );
    try {
      final response = await torClient
          .get(uri, const {'Accept': 'image/*'})
          .timeout(LinkUnfurlPolicy.fetchTimeout);

      if (response.statusCode < 200 || response.statusCode >= 400) {
        return null;
      }

      final bytes = await _readLimited(response, LinkUnfurlPolicy.maxImageBytes);
      return Uint8List.fromList(bytes);
    } catch (_) {
      return null;
    } finally {
      torClient.close();
    }
  }

  Future<List<int>> _readLimited(Stream<List<int>> stream, int maxBytes) async {
    final buffer = <int>[];
    await for (final chunk in stream) {
      buffer.addAll(chunk);
      if (buffer.length >= maxBytes) {
        return buffer.sublist(0, maxBytes);
      }
    }
    return buffer;
  }

  void _remember(String url, LinkPreview? preview) {
    if (_cache.length >= LinkUnfurlPolicy.maxCacheEntries) {
      _cache.remove(_cache.keys.first);
    }
    _cache[url] = preview;
  }

  void _rememberImage(String url, Uint8List? bytes) {
    if (_imageCache.length >= LinkUnfurlPolicy.maxCacheEntries) {
      _imageCache.remove(_imageCache.keys.first);
    }
    _imageCache[url] = bytes;
  }

  void clearCache() {
    _cache.clear();
    _imageCache.clear();
  }
}
