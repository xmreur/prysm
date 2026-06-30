import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:path/path.dart' as p;
import 'package:prysm/screens/widgets/image_send_preview_screen.dart';
import 'package:prysm/util/readable_file_policy.dart';

typedef SendFileCallback = void Function(
  Uint8List bytes,
  String fileName,
  String type, {
  bool viewOnce,
});

/// Shared routing for local attachment bytes (picker, drag-drop, etc.).
class ChatAttachmentIngress {
  ChatAttachmentIngress._();

  static const _imageExtensions = {
    'jpg',
    'jpeg',
    'png',
    'gif',
    'webp',
    'bmp',
    'heic',
    'heif',
    'tif',
    'tiff',
  };

  static bool isImageFileName(String fileName) {
    final ext = p.extension(fileName).toLowerCase().replaceFirst('.', '');
    if (ext.isNotEmpty && _imageExtensions.contains(ext)) {
      return true;
    }
    final mime = ReadableFilePolicy.mimeTypeFor(fileName)?.toLowerCase();
    return mime != null && mime.startsWith('image/');
  }

  static Future<Uint8List> prepareImageBytes(Uint8List bytes) async {
    if (bytes.length <= 500 * 1024) {
      return bytes;
    }

    try {
      return await FlutterImageCompress.compressWithList(
        bytes,
        minHeight: 1080,
        minWidth: 1080,
        quality: 70,
      );
    } catch (_) {
      return bytes;
    }
  }

  static Future<void> sendLocalAttachment({
    required BuildContext context,
    required Uint8List bytes,
    required String fileName,
    required SendFileCallback sendFile,
    bool forceImageFlow = false,
  }) async {
    if (forceImageFlow || isImageFileName(fileName)) {
      final prepared = await prepareImageBytes(bytes);
      if (!context.mounted) return;

      final viewOnce = await ImageSendPreviewScreen.open(context, prepared);
      if (viewOnce == null || !context.mounted) return;

      sendFile(prepared, fileName, 'image', viewOnce: viewOnce);
      return;
    }

    sendFile(bytes, fileName, 'file');
  }
}
