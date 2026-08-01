import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as path;
import 'package:prysm/models/release_info.dart';
import 'package:prysm/screens/widgets/update_available_dialog.dart';
import 'package:prysm/services/settings_service.dart';
import 'package:prysm/util/logging.dart';
import 'package:prysm/util/updater_downloader.dart';
import 'package:prysm/util/version_compare.dart';

enum UpdateCheckStatus {
  upToDate,
  updateAvailable,
  error,
}

class UpdateCheckResult {
  const UpdateCheckResult({
    required this.status,
    this.release,
    this.errorMessage,
  });

  final UpdateCheckStatus status;
  final ReleaseInfo? release;
  final String? errorMessage;
}

class AppUpdateService {
  static const String _releasesApiUrl =
      'https://api.github.com/repos/xmreur/prysm/releases/latest';

  static final AppUpdateService _instance = AppUpdateService._internal();
  factory AppUpdateService() => _instance;
  AppUpdateService._internal();

  Future<String> getCurrentVersion() async {
    if (Platform.isAndroid || Platform.isIOS) {
      final info = await PackageInfo.fromPlatform();
      return info.version.startsWith('v') ? info.version : 'v${info.version}';
    }
    return SettingsService.appVersion;
  }

  Future<ReleaseInfo> fetchLatestRelease() async {
    final response = await http.get(Uri.parse(_releasesApiUrl));
    if (response.statusCode != 200) {
      throw Exception(
        'Failed to fetch latest release (HTTP ${response.statusCode})',
      );
    }
    return ReleaseInfo.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  Future<UpdateCheckResult> checkForUpdate() async {
    try {
      final release = await fetchLatestRelease();
      final current = await getCurrentVersion();
      if (isNewerVersion(current, release.tagName)) {
        return UpdateCheckResult(
          status: UpdateCheckStatus.updateAvailable,
          release: release,
        );
      }
      return const UpdateCheckResult(status: UpdateCheckStatus.upToDate);
    } catch (e, st) {
      Logging.error('Update check failed: $e\n$st', 'AppUpdateService');
      return UpdateCheckResult(
        status: UpdateCheckStatus.error,
        errorMessage: e.toString(),
      );
    }
  }

  Future<void> checkOnStartup(BuildContext context) async {
    if (Platform.isIOS) return;

    try {
      final result = await checkForUpdate();
      if (result.status != UpdateCheckStatus.updateAvailable ||
          result.release == null) {
        return;
      }

      if (!context.mounted) return;

      if (Platform.isAndroid) {
        await _showAndroidUpdateDialog(context, result.release!);
      } else {
        await _launchDesktopUpdater(result.release!);
      }
    } catch (e) {
      Logging.error('Startup update check failed: $e', 'AppUpdateService');
    }
  }

  Future<String?> checkFromSettings(BuildContext context) async {
    final result = await checkForUpdate();
    switch (result.status) {
      case UpdateCheckStatus.upToDate:
        return 'Already at the latest version.';
      case UpdateCheckStatus.error:
        return result.errorMessage ?? 'Could not check for updates.';
      case UpdateCheckStatus.updateAvailable:
        final release = result.release!;
        if (!context.mounted) return null;
        if (Platform.isAndroid) {
          await _showAndroidUpdateDialog(context, release);
        } else {
          await _launchDesktopUpdater(release);
        }
        return null;
    }
  }

  String? androidApkUrl(ReleaseInfo release) {
    return release.assetUrl(ReleaseAssetNames.androidApk) ??
        release.assetUrlEndingWith('.apk');
  }

  String? desktopPackageUrl(ReleaseInfo release) {
    if (Platform.isWindows) {
      return release.assetUrl(ReleaseAssetNames.windowsZip);
    }
    if (Platform.isLinux) {
      return release.assetUrl(ReleaseAssetNames.linuxTarGz);
    }
    if (Platform.isMacOS) {
      return release.assetUrl(ReleaseAssetNames.macosZip);
    }
    return null;
  }

  String getDesktopInstallDir() {
    final exe = Platform.resolvedExecutable;
    if (Platform.isMacOS) {
      return path.normalize(path.join(path.dirname(exe), '..', '..'));
    }
    return path.dirname(exe);
  }

  Future<void> _launchDesktopUpdater(ReleaseInfo release) async {
    final packageUrl = desktopPackageUrl(release);
    if (packageUrl == null) {
      throw Exception('No desktop package found in release ${release.tagName}');
    }

    final updaterPath =
        await UpdaterDownloader().getOrDownloadUpdater(release: release);
    final installDir = getDesktopInstallDir();

    Logging.info('Launching updater for ${release.tagName}', 'AppUpdateService');
    await Process.start(
      updaterPath,
      ['--url', packageUrl, '--install-dir', installDir],
      mode: ProcessStartMode.detached,
    );
    exit(0);
  }

  Future<void> _showAndroidUpdateDialog(
    BuildContext context,
    ReleaseInfo release,
  ) async {
    final apkUrl = androidApkUrl(release);
    if (apkUrl == null) {
      Logging.warning(
        'No APK asset in release ${release.tagName}',
        'AppUpdateService',
      );
      return;
    }

    final accepted = await showUpdateAvailableDialog(
      context: context,
      tagName: release.tagName,
      releaseNotes: release.body,
    );
    if (accepted != true || !context.mounted) return;

    await showUpdateProgressDialog(
      context: context,
      apkUrl: apkUrl,
    );
  }

  /// Debug only: show the update-available dialog with mock data (no network).
  Future<void> debugPreviewUpdateDialog(BuildContext context) async {
    if (!kDebugMode) return;

    final accepted = await showUpdateAvailableDialog(
      context: context,
      tagName: 'v99.0.0-debug',
      releaseNotes:
          'Debug preview of the update dialog.\n\n'
          'No download runs from this action. Use "Test update flow" to '
          'exercise download and install against the latest GitHub release.',
    );
    if (accepted == true && context.mounted) {
      Logging.debug('Update dialog preview accepted (no download)', 'AppUpdateService');
    }
  }

  /// Debug only: run the update flow against the latest release, ignoring version.
  ///
  /// On Android this can download and trigger the system installer. On desktop
  /// this defaults to a dry-run that reports the updater URL and install dir
  /// without spawning the updater or exiting the app.
  Future<String?> debugTestUpdateFlow(
    BuildContext context, {
    bool dryRunDesktop = true,
  }) async {
    if (!kDebugMode) return 'Only available in debug builds.';

    try {
      final release = await fetchLatestRelease();
      if (!context.mounted) return null;

      if (Platform.isIOS) {
        return 'Updates are not available on iOS.';
      }

      if (Platform.isAndroid) {
        await _showAndroidUpdateDialog(context, release);
        return null;
      }

      final packageUrl = desktopPackageUrl(release);
      if (packageUrl == null) {
        return 'No desktop package in release ${release.tagName}.';
      }

      final installDir = getDesktopInstallDir();
      if (dryRunDesktop) {
        return 'Dry run (${release.tagName})\n'
            'url: $packageUrl\n'
            'install-dir: $installDir';
      }

      await _launchDesktopUpdater(release);
      return null;
    } catch (e, st) {
      Logging.error('Debug update test failed: $e\n$st', 'AppUpdateService');
      return e.toString();
    }
  }
}
