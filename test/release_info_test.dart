import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/models/release_info.dart';

void main() {
  group('ReleaseInfo', () {
    test('parses assets and resolves by filename', () {
      final release = ReleaseInfo.fromJson({
        'tag_name': 'v0.5.1',
        'body': 'Bug fixes',
        'assets': [
          {
            'name': 'prysm-android.apk',
            'browser_download_url': 'https://example.com/prysm-android.apk',
          },
          {
            'name': 'prysm-windows.zip',
            'browser_download_url': 'https://example.com/prysm-windows.zip',
          },
        ],
      });

      expect(release.tagName, 'v0.5.1');
      expect(release.body, 'Bug fixes');
      expect(
        release.assetUrl(ReleaseAssetNames.androidApk),
        'https://example.com/prysm-android.apk',
      );
      expect(
        release.assetUrlEndingWith('.apk'),
        'https://example.com/prysm-android.apk',
      );
    });
  });
}
