class LinkUnfurlPolicy {
  LinkUnfurlPolicy._();

  static const int maxHtmlBytes = 512 * 1024;
  static const int maxImageBytes = 2 * 1024 * 1024;
  static const Duration fetchTimeout = Duration(seconds: 8);
  static const int maxCacheEntries = 64;
  static const int maxTitleLength = 200;
  static const int maxDescriptionLength = 300;

  static bool isSafeToUnfurl(Uri uri) {
    if (!uri.hasScheme) return false;
    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') return false;

    final host = uri.host.toLowerCase();
    if (host.isEmpty) return false;
    if (host == 'localhost' || host.endsWith('.localhost')) return false;

    if (host == '::1' || host.startsWith('127.')) return false;
    if (host.startsWith('10.')) return false;
    if (host.startsWith('192.168.')) return false;

    final parts = host.split('.');
    if (parts.length == 4 && parts[0] == '172') {
      final second = int.tryParse(parts[1]);
      if (second != null && second >= 16 && second <= 31) return false;
    }

    if (host == '0.0.0.0') return false;
    return true;
  }

  static String? resolveUrl(Uri base, String? value) {
    if (value == null || value.isEmpty) return null;
    final parsed = Uri.tryParse(value);
    if (parsed == null) return null;
    if (parsed.hasScheme) return value;
    return base.resolve(value).toString();
  }
}
