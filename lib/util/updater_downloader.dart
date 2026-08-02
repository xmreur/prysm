import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:prysm/models/release_info.dart';
import 'package:prysm/util/logging.dart';

class UpdaterDownloader {
  static const _fallbackUpdaterTag = 'v0.0.2';
  static const _manifestUrl =
      'https://github.com/xmreur/prysm-resources/raw/refs/heads/main/updater/manifest.json';

  /// SHA-256 of prysm-auto-updater v0.0.1/v0.0.2 binaries (verified at import time).
  static const _embeddedHashes = <String, String>{
    'v0.0.2/${ReleaseAssetNames.updaterLinux}':
        '1a71394475247707209829e478a07be0c4773894c3de072ce944531227724dad',
    'v0.0.2/${ReleaseAssetNames.updaterWindows}':
        'c2b7534aeec7c1154abff48754ee7f1e14d425e2ed53a0627adbdd6c9e875f8e',
    'v0.0.2/${ReleaseAssetNames.updaterMacos}':
        '3b32b568046c87f8152977a8bbc2a212b96f427ed19591bcce97ed9dffa3f471',
    'v0.0.1/${ReleaseAssetNames.updaterLinux}':
        'ae667c8940ae4215ffe03998c8deb808dcbe8bff29166a51f0aa67e986ed1ca4',
    'v0.0.1/${ReleaseAssetNames.updaterWindows}':
        '5fa89e6070ff6c7b70ba62698b61d39e624f0a209730d5f1669b6d2ad27ee451',
    'v0.0.1/${ReleaseAssetNames.updaterMacos}':
        'e8aef94b89c30b10e86b0ddec7a0f6bc833f435a27e43de8a510499f3c016f6a',
  };

  /// Downloads the updater executable for the current platform if not already present.
  /// Returns the path to the updater executable.
  Future<String> getOrDownloadUpdater({ReleaseInfo? release}) async {
    final cacheTag = release?.tagName ?? _fallbackUpdaterTag;
    final executableName = _getUpdaterExecutableName();
    final supportDir = await getApplicationSupportDirectory();
    final String updaterDirPath =
        path.join(supportDir.path, 'updater', cacheTag);
    final Directory updaterDir = Directory(updaterDirPath);
    if (!updaterDir.existsSync()) {
      updaterDir.createSync(recursive: true);
    }

    final String updaterExecutablePath =
        path.join(updaterDirPath, executableName);

    final expectedHash = await _expectedSha256(
      cacheTag: cacheTag,
      executableName: executableName,
    );
    if (expectedHash == null) {
      throw Exception(
        'No SHA-256 checksum available for updater $executableName ($cacheTag)',
      );
    }

    if (File(updaterExecutablePath).existsSync()) {
      final cachedHash =
          _sha256Hex(await File(updaterExecutablePath).readAsBytes());
      if (cachedHash == expectedHash) {
        return updaterExecutablePath;
      }
      Logging.warning(
        'Cached updater hash mismatch — re-downloading',
        'UpdaterDownloader',
      );
      await File(updaterExecutablePath).delete();
    }

    final Uri downloadUri = await _getDownloadUri(release: release);

    final http.Response response = await http.get(downloadUri);

    if (response.statusCode != 200) {
      throw Exception('Failed to download updater executable');
    }

    final downloadedHash = _sha256Hex(response.bodyBytes);
    if (downloadedHash != expectedHash) {
      throw Exception('Downloaded updater failed SHA-256 verification');
    }

    final File file = File(updaterExecutablePath);
    await file.writeAsBytes(response.bodyBytes);

    if (!Platform.isWindows) {
      await Process.run('chmod', ['+x', updaterExecutablePath]);
    }

    Logging.debug(
      'Updater executable downloaded to $updaterExecutablePath',
      'UpdaterDownloader',
    );
    return updaterExecutablePath;
  }

  String _getUpdaterExecutableName() {
    if (Platform.isWindows) {
      return ReleaseAssetNames.updaterWindows;
    } else if (Platform.isMacOS) {
      return ReleaseAssetNames.updaterMacos;
    } else if (Platform.isLinux) {
      return ReleaseAssetNames.updaterLinux;
    } else {
      throw UnsupportedError('Unsupported platform');
    }
  }

  Future<Uri> _getDownloadUri({ReleaseInfo? release}) async {
    if (release != null) {
      final assetName = _getUpdaterExecutableName();
      final url = release.assetUrl(assetName);
      if (url != null) {
        return Uri.parse(url);
      }
    }

    final base =
        'https://github.com/xmreur/prysm-auto-updater/releases/download/$_fallbackUpdaterTag';
    if (Platform.isWindows) {
      return Uri.parse('$base/${ReleaseAssetNames.updaterWindows}');
    } else if (Platform.isMacOS) {
      return Uri.parse('$base/${ReleaseAssetNames.updaterMacos}');
    } else if (Platform.isLinux) {
      return Uri.parse('$base/${ReleaseAssetNames.updaterLinux}');
    }
    throw UnsupportedError('Unsupported platform');
  }

  Future<String?> _expectedSha256({
    required String cacheTag,
    required String executableName,
  }) async {
    final manifest = await _fetchManifest();
    for (final tag in [cacheTag, _fallbackUpdaterTag]) {
      final manifestKey = '$tag/$executableName';
      final fromManifest = _hashFromManifest(manifest, manifestKey);
      if (fromManifest != null) return fromManifest;
      final embedded = _embeddedHashes[manifestKey];
      if (embedded != null) return embedded;
    }
    return null;
  }

  Future<Map<String, dynamic>?> _fetchManifest() async {
    try {
      final response = await http.get(Uri.parse(_manifestUrl));
      if (response.statusCode != 200) return null;
      return jsonDecode(response.body) as Map<String, dynamic>;
    } catch (e) {
      Logging.error(
        'Updater manifest fetch failed: $e',
        'UpdaterDownloader',
      );
      return null;
    }
  }

  String? _hashFromManifest(Map<String, dynamic>? manifest, String key) {
    if (manifest == null) return null;
    final value = manifest[key];
    return value is String ? value.toLowerCase() : null;
  }

  static String _sha256Hex(List<int> bytes) {
    return sha256.convert(bytes).toString();
  }
}
