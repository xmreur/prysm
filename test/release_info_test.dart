import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/models/release_info.dart';

void main() {
  group('ReleaseInfo', () {
    test('parses assets and resolves versioned filenames', () {
      final release = ReleaseInfo.fromJson({
        'tag_name': 'v0.6.1-fix',
        'body': 'Bug fixes',
        'assets': [
          {
            'name': 'Prysm-android-v0.6.1-fix.apk',
            'browser_download_url': 'https://example.com/Prysm-android-v0.6.1-fix.apk',
          },
          {
            'name': 'Prysm-windows-x86_64-v0.6.1-fix.zip',
            'browser_download_url':
                'https://example.com/Prysm-windows-x86_64-v0.6.1-fix.zip',
          },
          {
            'name': 'Prysm-linux-x86_64-v0.6.1-fix.zip',
            'browser_download_url':
                'https://example.com/Prysm-linux-x86_64-v0.6.1-fix.zip',
          },
          {
            'name': 'Prysm-macos-v0.6.1-fix.zip',
            'browser_download_url':
                'https://example.com/Prysm-macos-v0.6.1-fix.zip',
          },
          {
            'name': 'Prysm-ios-v0.6.1-fix.ipa',
            'browser_download_url':
                'https://example.com/Prysm-ios-v0.6.1-fix.ipa',
          },
        ],
      });

      expect(release.tagName, 'v0.6.1-fix');
      expect(release.body, 'Bug fixes');
      expect(
        release.assetUrl(ReleaseAssetNames.androidApk('v0.6.1-fix')),
        'https://example.com/Prysm-android-v0.6.1-fix.apk',
      );
      expect(
        release.assetUrl(ReleaseAssetNames.windowsZip('v0.6.1-fix')),
        'https://example.com/Prysm-windows-x86_64-v0.6.1-fix.zip',
      );
      expect(
        release.assetUrl(ReleaseAssetNames.linuxZip('v0.6.1-fix')),
        'https://example.com/Prysm-linux-x86_64-v0.6.1-fix.zip',
      );
      expect(
        release.assetUrl(ReleaseAssetNames.macosZip('v0.6.1-fix')),
        'https://example.com/Prysm-macos-v0.6.1-fix.zip',
      );
      expect(
        release.assetUrl(ReleaseAssetNames.iosIpa('v0.6.1-fix')),
        'https://example.com/Prysm-ios-v0.6.1-fix.ipa',
      );
      expect(
        release.assetUrlEndingWith('.apk'),
        'https://example.com/Prysm-android-v0.6.1-fix.apk',
      );
    });

    test('ReleaseAssetNames builds expected versioned filenames', () {
      expect(
        ReleaseAssetNames.androidApk('v0.5.1'),
        'Prysm-android-v0.5.1.apk',
      );
      expect(
        ReleaseAssetNames.windowsZip('v0.5.1'),
        'Prysm-windows-x86_64-v0.5.1.zip',
      );
      expect(
        ReleaseAssetNames.linuxZip('v0.5.1'),
        'Prysm-linux-x86_64-v0.5.1.zip',
      );
      expect(
        ReleaseAssetNames.macosZip('v0.5.1'),
        'Prysm-macos-v0.5.1.zip',
      );
      expect(
        ReleaseAssetNames.iosIpa('v0.5.1'),
        'Prysm-ios-v0.5.1.ipa',
      );
    });
  });
}
