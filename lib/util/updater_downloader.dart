import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;


enum LinuxDistroType {
  debianBased,
  archBased,
  unknown,
}

class UpdaterDownloader {
  /// Downloads the downloader executable for the current platform if not already present
  /// returns the path to the downloader executable
  
  Future<String> getOrDownloadUpdater() async {
    final String updaterDirPath = path.dirname(Platform.resolvedExecutable);
    final Directory updaterDir = Directory(updaterDirPath);
    if (!updaterDir.existsSync()) {
      updaterDir.createSync(recursive: true);
    }

    final String updaterExecutableName = _getUpdaterExecutableName();
    final String updaterExecutablePath = path.join(updaterDirPath, updaterExecutableName);

    if (File(updaterExecutablePath).existsSync()) {
      return updaterExecutablePath;
    }

    final Uri downloadUri = await _getDownloadUri();


    final http.Response response = await http.get(downloadUri);

    if (response.statusCode != 200) {
      throw Exception("Failed to download Updater executable");
    }

    final File file = File(updaterExecutablePath);
    await file.writeAsBytes(response.bodyBytes);

    if (!Platform.isWindows) {
      await Process.run('chmod', ['+x', updaterExecutablePath]);
    }

    //print("Updater executable downloaded to $updaterExecutablePath");
    return updaterExecutablePath;
  }

  String _getUpdaterExecutableName() {
    if (Platform.isWindows) {
      return 'prysm-updater-windows.exe';
    } else if (Platform.isMacOS) {
      return 'prysm-updater-macos';
    } else if (Platform.isLinux) {
      return 'prysm-updater-linux';
    }
    else {
      throw UnsupportedError("Unsupported platform");
    }

  }


  Future<Uri> _getDownloadUri() async {
    // You can use official Updater project URLs or trusted mirrors.
    // These URLs must be valid direct download links for the platform Updater binaries.
    // Below are example placeholder URLs, replace with actual current URLs.
    if (Platform.isWindows) {
      return Uri.parse(
          'https://github.com/xmreur/prysm-auto-updater/releases/download/v0.0.1/prysm-updater-windows.exe');
    } else if (Platform.isMacOS) {
      return Uri.parse(
          'https://github.com/xmreur/prysm-auto-updater/releases/download/v0.0.1/prysm-updater-macos');
    } else if (Platform.isLinux) {
      return Uri.parse("https://github.com/xmreur/prysm-auto-updater/releases/download/v0.0.1/prysm-updater-linux");
      
    }
    throw UnsupportedError('Unsupported platform');
  }
}