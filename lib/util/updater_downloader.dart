import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:prysm/models/release_info.dart';
import 'package:prysm/util/logging.dart';

class UpdaterDownloader {
  /// Downloads the updater executable for the current platform if not already present.
  /// Returns the path to the updater executable.
  Future<String> getOrDownloadUpdater({ReleaseInfo? release}) async {
    final docDir = await getApplicationDocumentsDirectory();
    final String updaterDirPath = path.join(docDir.path, 'prysm', 'updater');
    final Directory updaterDir = Directory(updaterDirPath);
    if (!updaterDir.existsSync()) {
      updaterDir.createSync(recursive: true);
    }

    final String updaterExecutableName = _getUpdaterExecutableName();
    final String updaterExecutablePath =
        path.join(updaterDirPath, updaterExecutableName);

    if (File(updaterExecutablePath).existsSync()) {
      return updaterExecutablePath;
    }

    final Uri downloadUri = await _getDownloadUri(release: release);

    final http.Response response = await http.get(downloadUri);

    if (response.statusCode != 200) {
      throw Exception('Failed to download updater executable');
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

  // Fallback: prysm-auto-updater v0.0.1 when release assets are unavailable.
    const fallbackTag = 'v0.0.1';
    final base =
        'https://github.com/xmreur/prysm-auto-updater/releases/download/$fallbackTag';
    if (Platform.isWindows) {
      return Uri.parse('$base/${ReleaseAssetNames.updaterWindows}');
    } else if (Platform.isMacOS) {
      return Uri.parse('$base/${ReleaseAssetNames.updaterMacos}');
    } else if (Platform.isLinux) {
      return Uri.parse('$base/${ReleaseAssetNames.updaterLinux}');
    }
    throw UnsupportedError('Unsupported platform');
  }
}
