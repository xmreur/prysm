import 'package:flutter/widgets.dart';
import 'package:prysm/ui/core/prysm_dialog.dart';
import 'package:prysm/ui/core/prysm_toast.dart';
import 'dart:io';
import 'dart:typed_data';

import 'package:prysm/util/download_location.dart';
import 'package:prysm/util/readable_file_policy.dart';
import 'package:prysm/l10n/l10n_extensions.dart';

class FileDownloadHelper {
  FileDownloadHelper._();

  static Future<void> download(
    BuildContext context, {
    required String fileName,
    required Uint8List bytes,
    required FilePreviewCategory category,
  }) async {
    if (bytes.isEmpty) {
      if (!context.mounted) return;
      showPrysmToast(context, context.l10n.fileNotReadyToDownload);
      return;
    }

    if (ReadableFilePolicy.requiresDownloadWarning(category)) {
      final confirmed = await showPrysmConfirmDialog(
        context: context,
        title: context.l10n.downloadRiskyFile,
        content: Text(
          '$fileName may be harmful to your device. '
          'Only download if you trust the sender.',
        ),
        confirmLabel: 'Download anyway',
        cancelLabel: context.l10n.cancel,
      );
      if (confirmed != true || !context.mounted) return;
    }

    try {
      final file = await DownloadLocation.saveBytes(bytes, fileName);
      if (!context.mounted) return;
      showPrysmToast(
        context,
        'Saved ${file.path.split(Platform.pathSeparator).last}',
      );
    } catch (e) {
      if (!context.mounted) return;
      showPrysmToast(context, 'Download failed: $e');
    }
  }
}
