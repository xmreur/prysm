import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/util/link_unfurl_parser.dart';
import 'package:prysm/util/link_unfurl_policy.dart';

void main() {
  test('parses open graph metadata from html head', () {
    const html = '''
      <html><head>
        <meta property="og:title" content="Example Site" />
        <meta property="og:description" content="A short summary." />
        <meta property="og:image" content="https://example.com/preview.png" />
        <meta property="og:site_name" content="Example" />
      </head></html>
    ''';

    final preview = LinkUnfurlParser.parse('https://example.com/page', html);
    expect(preview, isNotNull);
    expect(preview!.title, 'Example Site');
    expect(preview.description, 'A short summary.');
    expect(preview.imageUrl, 'https://example.com/preview.png');
    expect(preview.siteName, 'Example');
  });

  test('allows onion and blocks local hosts', () {
    expect(
      LinkUnfurlPolicy.isSafeToUnfurl(Uri.parse('http://abc123.onion/page')),
      isTrue,
    );
    expect(
      LinkUnfurlPolicy.isSafeToUnfurl(Uri.parse('http://127.0.0.1/page')),
      isFalse,
    );
    expect(
      LinkUnfurlPolicy.isSafeToUnfurl(Uri.parse('https://example.com/page')),
      isTrue,
    );
  });

  test('resolves relative preview image urls', () {
    final base = Uri.parse('https://example.com/blog/post');
    expect(
      LinkUnfurlPolicy.resolveUrl(base, '/assets/preview.png'),
      'https://example.com/assets/preview.png',
    );
  });
}
