import 'package:prysm/models/link_preview.dart';
import 'package:prysm/util/link_unfurl_policy.dart';

class LinkUnfurlParser {
  LinkUnfurlParser._();

  static LinkPreview? parse(String url, String html) {
    final title = _truncate(
      _metaContent(html, 'og:title') ??
          _metaContent(html, 'twitter:title') ??
          _titleTag(html),
      LinkUnfurlPolicy.maxTitleLength,
    );
    final description = _truncate(
      _metaContent(html, 'og:description') ??
          _metaContent(html, 'twitter:description') ??
          _metaContent(html, 'description'),
      LinkUnfurlPolicy.maxDescriptionLength,
    );
    final imageUrl = _metaContent(html, 'og:image') ??
        _metaContent(html, 'twitter:image');
    final siteName =
        _metaContent(html, 'og:site_name') ?? Uri.tryParse(url)?.host;

    if ((title == null || title.isEmpty) &&
        (description == null || description.isEmpty) &&
        (imageUrl == null || imageUrl.isEmpty)) {
      return null;
    }

    return LinkPreview(
      url: url,
      title: title,
      description: description,
      imageUrl: imageUrl,
      siteName: siteName,
    );
  }

  static String? _metaContent(String html, String key) {
    final patterns = [
      RegExp(
        '<meta[^>]+(?:property|name)=["\']$key["\'][^>]+content=["\']([^"\']*)["\']',
        caseSensitive: false,
      ),
      RegExp(
        '<meta[^>]+content=["\']([^"\']*)["\'][^>]+(?:property|name)=["\']$key["\']',
        caseSensitive: false,
      ),
    ];
    for (final pattern in patterns) {
      final match = pattern.firstMatch(html);
      final value = match?.group(1)?.trim();
      if (value != null && value.isNotEmpty) return _decodeEntities(value);
    }
    return null;
  }

  static String? _titleTag(String html) {
    final match = RegExp(
      '<title[^>]*>([^<]*)</title>',
      caseSensitive: false,
    ).firstMatch(html);
    final value = match?.group(1)?.trim();
    if (value == null || value.isEmpty) return null;
    return _decodeEntities(value);
  }

  static String? _truncate(String? value, int maxLength) {
    if (value == null || value.isEmpty) return null;
    if (value.length <= maxLength) return value;
    return '${value.substring(0, maxLength - 1)}…';
  }

  static String _decodeEntities(String value) {
    return value
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&apos;', "'");
  }
}
