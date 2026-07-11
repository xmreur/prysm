import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:pointycastle/digests/sha256.dart';
import 'package:prysm/util/logging.dart';

enum LinuxDistroType {
  debianBased,
  archBased,
  fedoraBased,
  unknown,
}

class TorDownloader {
  static const _manifestUrl =
      'https://github.com/xmreur/prysm-resources/raw/refs/heads/main/tor/exec/manifest.json';

  Future<String> getOrDownloadTor() async {
    final Directory appDocDir = await getApplicationDocumentsDirectory();
    final String torDirPath =
        path.join(appDocDir.path, 'prysm', 'tor_executable');
    final Directory torDir = Directory(torDirPath);
    if (!torDir.existsSync()) {
      torDir.createSync(recursive: true);
    }

    final String torExecutableName = _getTorExecutableName();
    final String torExecutablePath = path.join(torDirPath, torExecutableName);
    final manifestKey = await _manifestKeyForPlatform();
    final expectedHash = await _fetchExpectedHash(manifestKey);

    if (File(torExecutablePath).existsSync()) {
      if (expectedHash == null ||
          _sha256Hex(await File(torExecutablePath).readAsBytes()) ==
              expectedHash.toLowerCase()) {
        return torExecutablePath;
      }
      Logging.error('Tor binary hash mismatch — re-downloading', 'TorDownloader');
      await File(torExecutablePath).delete();
    }

    final Uri downloadUri = await _getDownloadUri();
    Logging.debug('Downloading Tor from $downloadUri ...', 'TorDownloader');

    final http.Response response = await http.get(downloadUri);
    if (response.statusCode != 200) {
      throw Exception('Failed to download Tor executable');
    }

    if (expectedHash != null &&
        _sha256Hex(response.bodyBytes) != expectedHash.toLowerCase()) {
      throw Exception('Downloaded Tor binary failed SHA256 verification');
    }

    final File file = File(torExecutablePath);
    await file.writeAsBytes(response.bodyBytes);

    if (!Platform.isWindows) {
      await Process.run('chmod', ['+x', torExecutablePath]);
    }

    Logging.debug('Tor executable downloaded to $torExecutablePath', 'TorDownloader');
    return torExecutablePath;
  }

  String _getTorExecutableName() {
    if (Platform.isWindows) {
      return 'tor.exe';
    } else if (Platform.isMacOS) {
      return 'tor_macos';
    } else if (Platform.isLinux) {
      return 'tor';
    } else {
      throw UnsupportedError('Unsupported platform');
    }
  }

  Future<LinuxDistroType> detectLinuxDistroType() async {
    try {
      final content = await File('/etc/os-release').readAsString();
      final lc = content.toLowerCase();
      if (lc.contains('arch')) return LinuxDistroType.archBased;
      if (lc.contains('fedora') ||
          lc.contains('rhel') ||
          lc.contains('centos')) {
        return LinuxDistroType.fedoraBased;
      }
      if (lc.contains('debian') ||
          lc.contains('ubuntu') ||
          lc.contains('mint')) {
        return LinuxDistroType.debianBased;
      }
    } catch (_) {}
    return LinuxDistroType.unknown;
  }

  Future<String> _manifestKeyForPlatform() async {
    if (Platform.isWindows) return 'windows/tor.exe';
    if (Platform.isMacOS) return 'macos/tor';
    if (Platform.isLinux) {
      return switch (await detectLinuxDistroType()) {
        LinuxDistroType.debianBased => 'linux/deb/tor',
        LinuxDistroType.archBased => 'linux/arch/tor',
        LinuxDistroType.fedoraBased => 'linux/generic/tor',
        LinuxDistroType.unknown => 'linux/generic/tor',
      };
    }
    throw UnsupportedError('Unsupported platform');
  }

  Future<Uri> _getDownloadUri() async {
    if (Platform.isWindows) {
      return Uri.parse(
        'https://github.com/xmreur/prysm-resources/raw/refs/heads/main/tor/exec/windows/tor.exe',
      );
    } else if (Platform.isMacOS) {
      return Uri.parse(
        'https://github.com/xmreur/prysm-resources/raw/refs/heads/main/tor/exec/macos/tor',
      );
    } else if (Platform.isLinux) {
      final linuxDistro = await detectLinuxDistroType();
      if (linuxDistro == LinuxDistroType.debianBased) {
        return Uri.parse(
          'https://github.com/xmreur/prysm-resources/raw/refs/heads/main/tor/exec/linux/deb/tor',
        );
      } else if (linuxDistro == LinuxDistroType.archBased) {
        return Uri.parse(
          'https://github.com/xmreur/prysm-resources/raw/refs/heads/main/tor/exec/linux/arch/tor',
        );
      }
      return Uri.parse(
        'https://github.com/xmreur/prysm-resources/raw/refs/heads/main/tor/exec/linux/generic/tor',
      );
    }
    throw UnsupportedError('Unsupported platform');
  }

  Future<String?> _fetchExpectedHash(String manifestKey) async {
    try {
      final response = await http.get(Uri.parse(_manifestUrl));
      if (response.statusCode != 200) return null;
      final map = jsonDecode(response.body) as Map<String, dynamic>;
      final value = map[manifestKey];
      return value is String ? value : null;
    } catch (e) {
      Logging.error('Tor manifest fetch failed (skipping verify): $e', 'TorDownloader');
      return null;
    }
  }

  static String _sha256Hex(List<int> bytes) {
    final digest = SHA256Digest();
    final hash = digest.process(Uint8List.fromList(bytes));
    return hash.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}
