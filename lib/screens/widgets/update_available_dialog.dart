import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:open_file/open_file.dart';
import 'package:ota_update/ota_update.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:prysm/main.dart';
import 'package:prysm/theme/prysm_style_scope.dart';
import 'package:prysm/ui/core/prysm_dialog.dart';
import 'package:prysm/ui/core/prysm_pressable.dart';

Future<bool?> showUpdateAvailableDialog({
  required BuildContext context,
  required String tagName,
  required String releaseNotes,
}) {
  final notes = releaseNotes.trim();
  return showPrysmConfirmDialog(
    context: context,
    title: 'Update available ($tagName)',
    content: _ReleaseNotesContent(notes: notes),
    confirmLabel: 'Update now',
    cancelLabel: 'Later',
  );
}

class _ReleaseNotesContent extends StatelessWidget {
  const _ReleaseNotesContent({required this.notes});

  final String notes;

  @override
  Widget build(BuildContext context) {
    final style = context.prysmStyle;
    final tokens = style.tokens;

    if (notes.isEmpty) {
      return Text(
        'A new version is available.',
        style: style.bodyStyle,
      );
    }

    return Markdown(
      data: notes,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      styleSheet: MarkdownStyleSheet(
        p: style.bodyStyle,
        h1: style.headlineStyle,
        h2: style.titleStyle.copyWith(
          fontSize: (style.titleStyle.fontSize ?? 16) * 1.05,
          fontWeight: FontWeight.w600,
        ),
        h3: style.titleStyle,
        listBullet: style.bodyStyle,
        listIndent: 24,
        strong: style.bodyStyle.copyWith(fontWeight: FontWeight.w600),
        em: style.bodyStyle.copyWith(fontStyle: FontStyle.italic),
        code: style.monoStyle.copyWith(
          backgroundColor: tokens.surfaceElevated,
        ),
        codeblockDecoration: BoxDecoration(
          color: tokens.surfaceElevated,
          borderRadius: BorderRadius.circular(8),
        ),
        codeblockPadding: const EdgeInsets.all(12),
        blockquote: style.bodyStyle.copyWith(color: tokens.textMuted),
        blockquoteDecoration: BoxDecoration(
          border: Border(
            left: BorderSide(color: tokens.outline, width: 3),
          ),
        ),
        horizontalRuleDecoration: BoxDecoration(
          border: Border(
            top: BorderSide(color: tokens.outline.withValues(alpha: 0.5)),
          ),
        ),
        a: style.bodyStyle.copyWith(color: tokens.accent),
      ),
    );
  }
}

Future<void> showUpdateProgressDialog({
  required BuildContext context,
  required String apkUrl,
}) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: false,
    barrierLabel: 'Downloading update',
    barrierColor: const Color(0x80000000),
    pageBuilder: (dialogContext, animation, secondaryAnimation) {
      return Center(
        child: _UpdateProgressDialog(apkUrl: apkUrl),
      );
    },
    transitionBuilder: (context, animation, secondaryAnimation, child) {
      return FadeTransition(opacity: animation, child: child);
    },
  );
}

class _UpdateProgressDialog extends StatefulWidget {
  const _UpdateProgressDialog({required this.apkUrl});

  final String apkUrl;

  @override
  State<_UpdateProgressDialog> createState() => _UpdateProgressDialogState();
}

class _UpdateProgressDialogState extends State<_UpdateProgressDialog>
    with WidgetsBindingObserver {
  static const _apkFileName = 'prysm-update.apk';

  final OtaUpdate _otaUpdate = OtaUpdate();
  StreamSubscription<OtaEvent>? _subscription;

  double _progress = 0;
  String _status = 'Downloading update…';
  bool _failed = false;
  bool _canceled = false;
  bool _downloadComplete = false;
  bool _needsInstallPermission = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_beginUpdate());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _subscription?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_handleAppResumed());
    }
  }

  Future<void> _handleAppResumed() async {
    if (!mounted || _failed || _canceled || !_needsInstallPermission) return;
    if (!await _hasInstallPermission()) return;

    _needsInstallPermission = false;
    if (_downloadComplete) {
      await _launchDownloadedApk();
      return;
    }

    if (_subscription == null) {
      _startDownload();
    }
  }

  Future<bool> _hasInstallPermission() async {
    return (await Permission.requestInstallPackages.status).isGranted;
  }

  Future<bool> _requestInstallPermission() async {
    if (await _hasInstallPermission()) return true;

    setState(() {
      _needsInstallPermission = true;
      _status =
          'Allow Prysm to install updates in Settings, then return here.';
      _progress = 0;
    });

    final result = await Permission.requestInstallPackages.request();
    return result.isGranted;
  }

  Future<void> _beginUpdate() async {
    final granted = await _requestInstallPermission();
    if (!mounted) return;
    if (!granted) {
      setState(() {
        _failed = true;
        _status =
            'Install permission is required to update Prysm. Open Settings to allow it, then try again.';
      });
      return;
    }

    _needsInstallPermission = false;
    _startDownload();
  }

  Future<String> _apkPath() async {
    final dir = await getApplicationDocumentsDirectory();
    return p.join(dir.path, 'ota_update', _apkFileName);
  }

  Future<void> _launchDownloadedApk() async {
    final apkPath = await _apkPath();
    if (!File(apkPath).existsSync()) return;

    setState(() {
      _status = 'Installing update…';
      _progress = 1;
    });

    final result = await OpenFile.open(apkPath);
    if (!mounted) return;
    if (result.type != ResultType.done) {
      setState(() {
        _failed = true;
        _status = result.message;
      });
      return;
    }
    _handOffToInstaller();
  }

  Future<void> _openInstallSettings() async {
    setState(() {
      _failed = false;
      _needsInstallPermission = true;
      _status =
          'Allow Prysm to install updates in Settings, then return here.';
    });
    await Permission.requestInstallPackages.request();
    if (!mounted) return;
    await _handleAppResumed();
  }

  Future<void> _cancelDownload() async {
    if (_canceled) return;
    _canceled = true;
    await _otaUpdate.cancel();
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _onInstalling() async {
    final needsPermission = !await _hasInstallPermission();
    if (!mounted) return;
    setState(() {
      _needsInstallPermission = needsPermission;
      _status = needsPermission
          ? 'Allow Prysm to install updates in Settings, then return here.'
          : 'Installing update…';
      _progress = 1;
    });
    if (!needsPermission) {
      _handOffToInstaller();
    }
  }

  void _handOffToInstaller() {
    Future<void>.delayed(
      const Duration(milliseconds: 400),
      () => unawaited(shutdownForAndroidUpdate()),
    );
  }

  void _startDownload() {
    _subscription?.cancel();
    _subscription = _otaUpdate
        .execute(
          widget.apkUrl,
          destinationFilename: _apkFileName,
        )
        .listen(
      (event) {
        if (!mounted) return;
        switch (event.status) {
          case OtaStatus.DOWNLOADING:
            setState(() {
              _status = 'Downloading update…';
              final parsed = double.tryParse(event.value ?? '');
              if (parsed != null) {
                _progress = parsed / 100;
              }
            });
          case OtaStatus.INSTALLING:
            _downloadComplete = true;
            unawaited(_onInstalling());
          case OtaStatus.INSTALLATION_DONE:
            _handOffToInstaller();
          case OtaStatus.PERMISSION_NOT_GRANTED_ERROR:
            _downloadComplete = true;
            setState(() {
              _needsInstallPermission = true;
              _status =
                  'Allow Prysm to install updates in Settings, then return here.';
            });
          case OtaStatus.ALREADY_RUNNING_ERROR:
          case OtaStatus.INTERNAL_ERROR:
          case OtaStatus.DOWNLOAD_ERROR:
          case OtaStatus.INSTALLATION_ERROR:
          case OtaStatus.CHECKSUM_ERROR:
            setState(() {
              _failed = true;
              _status = event.value ?? 'Update failed';
            });
          case OtaStatus.CANCELED:
            if (mounted) Navigator.of(context).pop();
        }
      },
      onError: (Object e) {
        if (!mounted) return;
        setState(() {
          _failed = true;
          _status = e.toString();
        });
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final style = context.prysmStyle;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 320),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: style.tokens.surface,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Updating Prysm', style: style.headlineStyle),
              const SizedBox(height: 16),
              Text(_status, style: style.bodyStyle),
              const SizedBox(height: 12),
              if (!_failed && !_canceled)
                _DownloadProgressBar(
                  progress: _progress,
                  trackColor: style.tokens.outline.withValues(alpha: 0.3),
                  fillColor: style.tokens.accent,
                ),
              if (!_failed && !_canceled) ...[
                const SizedBox(height: 16),
                Align(
                  alignment: Alignment.centerRight,
                  child: PrysmPressable(
                    onTap: () => unawaited(_cancelDownload()),
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Text('Cancel', style: style.bodyStyle),
                    ),
                  ),
                ),
              ],
              if (_failed) ...[
                const SizedBox(height: 12),
                if (_needsInstallPermission)
                  PrysmPressable(
                    onTap: () => unawaited(_openInstallSettings()),
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Text('Open Settings', style: style.bodyStyle),
                    ),
                  ),
                PrysmPressable(
                  onTap: () => Navigator.of(context).pop(),
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text('Close', style: style.bodyStyle),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _DownloadProgressBar extends StatelessWidget {
  const _DownloadProgressBar({
    required this.progress,
    required this.trackColor,
    required this.fillColor,
  });

  final double progress;
  final Color trackColor;
  final Color fillColor;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: SizedBox(
        height: 6,
        child: Stack(
          children: [
            ColoredBox(color: trackColor, child: const SizedBox.expand()),
            if (progress > 0)
              FractionallySizedBox(
                widthFactor: progress.clamp(0, 1),
                child: ColoredBox(color: fillColor, child: const SizedBox(height: 6)),
              ),
          ],
        ),
      ),
    );
  }
}
