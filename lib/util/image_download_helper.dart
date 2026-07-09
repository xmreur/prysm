import 'package:flutter/widgets.dart';
import 'package:prysm/ui/core/prysm_toast.dart';
import 'dart:io';
import 'dart:typed_data';

import 'package:gal/gal.dart';
import 'package:prysm/services/image_attachment_cache.dart';
import 'package:prysm/util/download_location.dart';

class ImageDownloadHelper {
  ImageDownloadHelper._();

  static String extensionForMime(String mimeType) {
    switch (mimeType) {
      case 'image/png':
        return 'png';
      case 'image/webp':
        return 'webp';
      case 'image/gif':
        return 'gif';
      default:
        return 'jpg';
    }
  }

  static String _nameWithoutExtension(String fileName) {
    final dot = fileName.lastIndexOf('.');
    if (dot <= 0) return fileName;
    return fileName.substring(0, dot);
  }

  static Future<void> saveToDevice(
    BuildContext context, {
    required Uint8List bytes,
    String? mimeType,
    String? baseName,
  }) async {
    if (bytes.isEmpty) {
      if (!context.mounted) return;
      showPrysmToast(context, 'Image not ready to save');
      return;
    }

    final mime = mimeType ?? ImageAttachmentCache.sniffImageMimeType(bytes);
    final ext = extensionForMime(mime);
    final fileName =
        baseName ?? 'prysm_image_${DateTime.now().millisecondsSinceEpoch}.$ext';
    final galleryName = _nameWithoutExtension(fileName);

    try {
      if (Platform.isAndroid || Platform.isIOS) {
        final granted = await Gal.requestAccess();
        if (!granted) {
          if (!context.mounted) return;
          showPrysmToast(context, 'Gallery access denied');
          return;
        }
        await Gal.putImageBytes(bytes, name: galleryName);
        if (!context.mounted) return;
        showPrysmToast(context, 
              Platform.isAndroid ? 'Saved to gallery' : 'Saved to Photos',
            );
        return;
      }

      final file = await DownloadLocation.saveBytes(bytes, fileName);
      if (!context.mounted) return;
      showPrysmToast(
        context,
        'Image saved (${file.path.split(Platform.pathSeparator).last})',
      );
    } catch (e) {
      if (!context.mounted) return;
      showPrysmToast(context, 'Could not save image: $e');
    }
  }
}
