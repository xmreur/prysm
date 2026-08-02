class ReleaseAsset {
  const ReleaseAsset({
    required this.name,
    required this.browserDownloadUrl,
  });

  final String name;
  final String browserDownloadUrl;

  factory ReleaseAsset.fromJson(Map<String, dynamic> json) {
    return ReleaseAsset(
      name: json['name'] as String,
      browserDownloadUrl: json['browser_download_url'] as String,
    );
  }
}

class ReleaseInfo {
  const ReleaseInfo({
    required this.tagName,
    required this.body,
    required this.assets,
  });

  final String tagName;
  final String body;
  final List<ReleaseAsset> assets;

  factory ReleaseInfo.fromJson(Map<String, dynamic> json) {
    final rawAssets = json['assets'] as List<dynamic>? ?? [];
    return ReleaseInfo(
      tagName: json['tag_name'] as String,
      body: json['body'] as String? ?? '',
      assets: rawAssets
          .map((a) => ReleaseAsset.fromJson(a as Map<String, dynamic>))
          .toList(),
    );
  }

  String? assetUrl(String filename) {
    for (final asset in assets) {
      if (asset.name == filename) return asset.browserDownloadUrl;
    }
    return null;
  }

  String? assetUrlEndingWith(String suffix) {
    for (final asset in assets) {
      if (asset.name.endsWith(suffix)) return asset.browserDownloadUrl;
    }
    return null;
  }
}

/// GitHub release asset filenames published by CI.
abstract final class ReleaseAssetNames {
  static String androidApk(String tagName) => 'Prysm-android-$tagName.apk';
  static String iosIpa(String tagName) => 'Prysm-ios-$tagName.ipa';
  static String windowsZip(String tagName) =>
      'Prysm-windows-x86_64-$tagName.zip';
  static String linuxZip(String tagName) => 'Prysm-linux-x86_64-$tagName.zip';
  static String macosZip(String tagName) => 'Prysm-macos-$tagName.zip';

  /// Legacy filenames from releases before versioned asset naming.
  static const legacyAndroidApk = 'prysm-android.apk';
  static const legacyWindowsZip = 'prysm-windows.zip';
  static const legacyLinuxTarGz = 'prysm-linux.tar.gz';
  static const legacyMacosZip = 'prysm-macos.zip';

  static const updaterWindows = 'prysm-updater-windows.exe';
  static const updaterLinux = 'prysm-updater-linux';
  static const updaterMacos = 'prysm-updater-macos';
}
