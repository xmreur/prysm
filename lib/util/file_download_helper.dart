import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:prysm/util/download_location.dart';
import 'package:prysm/util/readable_file_policy.dart';

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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('File not ready to download')),
      );
      return;
    }

    if (ReadableFilePolicy.requiresDownloadWarning(category)) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Download risky file?'),
          content: Text(
            '$fileName may be harmful to your device. '
            'Only download if you trust the sender.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Download anyway'),
            ),
          ],
        ),
      );
      if (confirmed != true || !context.mounted) return;
    }

    try {
      final file = await DownloadLocation.saveBytes(bytes, fileName);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Saved ${file.path.split(Platform.pathSeparator).last}',
          ),
        ),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Download failed: $e')),
      );
    }
  }
}
