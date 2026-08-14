import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

/// Resolves the bundled lyrebird obfs4 client on desktop platforms.
class LyrebirdLocator {
  LyrebirdLocator({
    AssetBundle? assetBundle,
    Future<Directory> Function()? applicationSupportDirectory,
  })  : _assetBundle = assetBundle,
        _applicationSupportDirectory = applicationSupportDirectory;

  final AssetBundle? _assetBundle;
  final Future<Directory> Function()? _applicationSupportDirectory;

  static const bundledMissingMessage =
      'lyrebird is not bundled for this platform — build with tool/fetch_lyrebird.sh';

  Future<String> resolveLyrebirdPath() async {
    if (Platform.isAndroid || Platform.isIOS) {
      throw UnsupportedError('Lyrebird is embedded via IPtProxy on mobile');
    }

    final bundled = bundledPathNextToExecutable();
    if (bundled != null) {
      return bundled;
    }

    return _extractFromAssets();
  }

  /// Paths where CMake / Xcode install lyrebird next to the app bundle.
  static List<String> candidateBundledPaths() {
    final exeDir = path.dirname(Platform.resolvedExecutable);
    if (Platform.isLinux) {
      return [path.join(exeDir, 'lib', 'lyrebird')];
    }
    if (Platform.isWindows) {
      return [path.join(exeDir, 'lyrebird.exe')];
    }
    if (Platform.isMacOS) {
      final resourcesDir = path.normalize(path.join(exeDir, '..', 'Resources'));
      return [
        path.join(resourcesDir, 'lyrebird'),
        path.join(exeDir, 'lyrebird'),
      ];
    }
    return const [];
  }

  static String? bundledPathNextToExecutable() {
    for (final candidate in candidateBundledPaths()) {
      if (File(candidate).existsSync()) {
        return candidate;
      }
    }
    return null;
  }

  static String assetKeyForCurrentPlatform() {
    if (Platform.isWindows) {
      return 'assets/native/pt/windows/lyrebird.exe';
    }
    if (Platform.isMacOS) {
      return 'assets/native/pt/macos/lyrebird';
    }
    if (Platform.isLinux) {
      final arch = linuxAssetArch();
      return 'assets/native/pt/linux/$arch/lyrebird';
    }
    throw UnsupportedError('Unsupported platform');
  }

  static String linuxAssetArch() {
    final machine = Platform.environment['LYREBIRD_ARCH'] ??
        _unameMachineSync();
    switch (machine) {
      case 'aarch64':
      case 'arm64':
        return 'arm64';
      default:
        return 'amd64';
    }
  }

  static String _unameMachineSync() {
    try {
      final result = Process.runSync('uname', ['-m']);
      if (result.exitCode == 0) {
        return (result.stdout as String).trim().toLowerCase();
      }
    } catch (_) {}
    return 'x86_64';
  }

  Future<String> _extractFromAssets() async {
    final assetKey = assetKeyForCurrentPlatform();
    final bundle = _assetBundle ?? rootBundle;

    late final ByteData data;
    try {
      data = await bundle.load(assetKey);
    } catch (_) {
      throw StateError(bundledMissingMessage);
    }

    final supportDir = await (_applicationSupportDirectory ??
        getApplicationSupportDirectory)();
    final destDir = Directory(path.join(supportDir.path, 'prysm', 'pt'));
    if (!destDir.existsSync()) {
      destDir.createSync(recursive: true);
    }

    final fileName = Platform.isWindows ? 'lyrebird.exe' : 'lyrebird';
    final destPath = path.join(destDir.path, fileName);
    final destFile = File(destPath);
    final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);

    if (!destFile.existsSync() || destFile.lengthSync() != bytes.length) {
      await destFile.writeAsBytes(bytes, flush: true);
      if (!Platform.isWindows) {
        await Process.run('chmod', ['+x', destPath]);
      }
    }

    return destPath;
  }
}
