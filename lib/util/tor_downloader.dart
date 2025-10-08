import 'dart:io';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

class TorDownloader {
  /// Downloads the tor executable for the current platform if not already present
  /// returns the path to the tor executable
  
  Future<String> getOrDownloadTor() async {
    final Directory appDocDir = await getApplicationDocumentsDirectory();
    final String torDirPath = path.join(appDocDir.path, 'prysm', 'tor_executable');
    final Directory torDir = Directory(torDirPath);
    if (!torDir.existsSync()) {
      torDir.createSync(recursive: true);
    }

    final String torExecutableName = _getTorExecutableName();
    final String torExecutablePath = path.join(torDirPath, torExecutableName);

    if (File(torExecutablePath).existsSync()) {
      return torExecutablePath;
    }

    final Uri downloadUri = _getDownloadUri();

    //print("Downloading Tor from $downloadUri ...");

    final http.Response response = await http.get(downloadUri);

    if (response.statusCode != 200) {
      throw Exception("Failed to download Tor executable");
    }

    // On Windows and macOS, the download is usually a zip or dmg that needs extracting.
    // For simplicity, here we assume we download a single executable binary or a tarball.
    // In practice, you need to handle archive extraction (e.g., using `archive` package).
    // For demo purposes, let's assume direct binary download.

    final File file = File(torExecutablePath);
    await file.writeAsBytes(response.bodyBytes);

    if (!Platform.isWindows) {
      await Process.run('chmod', ['+x', torExecutablePath]);
    }

    // print("Tor executable downloaded to $torExecutablePath");
    return torExecutablePath;
  }

  String _getTorExecutableName() {
    if (Platform.isWindows) {
      return 'tor.exe';
    } else if (Platform.isMacOS) {
      return 'tor_macos';
    } else if (Platform.isLinux) {
      return 'tor';
    }
    else {
      throw UnsupportedError("Unsupported platform");
    }
  }

  Uri _getDownloadUri() {
    // You can use official Tor project URLs or trusted mirrors.
    // These URLs must be valid direct download links for the platform Tor binaries.
    // Below are example placeholder URLs, replace with actual current URLs.
    if (Platform.isWindows) {
      return Uri.parse(
          'https://github.com/xmreur/prysm-resources/raw/refs/heads/main/tor/exec/windows/tor.exe');
    } else if (Platform.isMacOS) {
      return Uri.parse(
          'https://github.com/xmreur/prysm-resources/raw/refs/heads/main/tor/exec/macos/tor');
    } else if (Platform.isLinux) {
      return Uri.parse(
          'https://github.com/xmreur/prysm-resources/raw/refs/heads/main/tor/exec/linux/tor');
    } else {
      throw UnsupportedError('Unsupported platform');
    }
  }
}