class UrlDetector {
  UrlDetector._();

  static final RegExp urlRegex = RegExp(
    r'https?://[^\s<>\[\]{}|\\^`]+',
    caseSensitive: false,
  );

  static String? firstUrl(String text) {
    final match = urlRegex.firstMatch(text);
    return match?.group(0);
  }
}
