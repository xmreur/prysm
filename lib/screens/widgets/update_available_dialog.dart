import 'package:flutter/widgets.dart';
import 'package:ota_update/ota_update.dart';
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
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (notes.isNotEmpty) ...[
          Text(notes, style: context.prysmStyle.bodyStyle),
        ] else
          Text(
            'A new version is available.',
            style: context.prysmStyle.bodyStyle,
          ),
      ],
    ),
    confirmLabel: 'Update now',
    cancelLabel: 'Later',
  );
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

class _UpdateProgressDialogState extends State<_UpdateProgressDialog> {
  double _progress = 0;
  String _status = 'Downloading update…';
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _startDownload();
  }

  Future<void> _startDownload() async {
    try {
      await for (final event in OtaUpdate().execute(
        widget.apkUrl,
        destinationFilename: 'prysm-update.apk',
      )) {
        if (!mounted) return;
        switch (event.status) {
          case OtaStatus.DOWNLOADING:
            setState(() {
              _status = 'Downloading update…';
              final value = event.value;
              if (value is int || value is double) {
                _progress = (value as num) / 100;
              }
            });
          case OtaStatus.INSTALLING:
            setState(() {
              _status = 'Installing update…';
              _progress = 1;
            });
          case OtaStatus.INSTALLATION_DONE:
            if (mounted) Navigator.of(context).pop();
          case OtaStatus.ALREADY_RUNNING_ERROR:
          case OtaStatus.PERMISSION_NOT_GRANTED_ERROR:
          case OtaStatus.INTERNAL_ERROR:
          case OtaStatus.DOWNLOAD_ERROR:
          case OtaStatus.INSTALLATION_ERROR:
          case OtaStatus.CHECKSUM_ERROR:
            setState(() {
              _failed = true;
              _status = event.value?.toString() ?? 'Update failed';
            });
          case OtaStatus.CANCELED:
            if (mounted) Navigator.of(context).pop();
        }
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _failed = true;
        _status = e.toString();
      });
    }
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
              if (!_failed)
                _DownloadProgressBar(
                  progress: _progress,
                  trackColor: style.tokens.outline.withValues(alpha: 0.3),
                  fillColor: style.tokens.accent,
                ),
              if (_failed) ...[
                const SizedBox(height: 12),
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
