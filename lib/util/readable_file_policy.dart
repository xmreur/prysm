import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;

enum FilePreviewCategory {
  text,
  pdf,
  spreadsheet,
  document,
  presentation,
  video,
  audio,
  blocked,
  binary,
}

class ReadableFilePolicy {
  ReadableFilePolicy._();

  /// Files larger than this skip in-app preview to limit memory use.
  static const maxPreviewBytes = 10 * 1024 * 1024;
  static const textSnippetBytes = 4 * 1024;
  static const textSnippetLines = 8;
  static const spreadsheetBubbleRows = 4;
  static const spreadsheetBubbleCols = 5;
  static const spreadsheetFullMaxRows = 50;

  static const _blockedExtensions = {
    'exe', 'dll', 'so', 'dylib', 'bat', 'cmd', 'ps1', 'sh', 'bash',
    'msi', 'dmg', 'apk', 'jar', 'deb', 'rpm', 'appimage', 'scr', 'vbs',
    'com', 'reg', 'lnk',
  };

  static const _videoExtensions = {
    'mp4', 'mov', 'webm', 'mkv', 'avi', 'm4v', '3gp', 'wmv', 'mpeg', 'mpg',
  };

  static const _audioExtensions = {
    'mp3', 'wav', 'ogg', 'oga', 'flac', 'm4a', 'aac', 'opus', 'wma',
  };

  static FilePreviewCategory categorize(String fileName) {
    final ext = p.extension(fileName).toLowerCase().replaceFirst('.', '');
    if (ext.isNotEmpty && _blockedExtensions.contains(ext)) {
      return FilePreviewCategory.blocked;
    }

    switch (ext) {
      case 'pdf':
        return FilePreviewCategory.pdf;
      case 'xlsx':
        return FilePreviewCategory.spreadsheet;
      case 'docx':
        return FilePreviewCategory.document;
      case 'pptx':
      case 'ppt':
      case 'odp':
        return FilePreviewCategory.presentation;
      case 'txt':
      case 'md':
      case 'csv':
      case 'json':
      case 'xml':
      case 'log':
      case 'yaml':
      case 'yml':
      case 'html':
      case 'htm':
        return FilePreviewCategory.text;
      case 'xls':
      case 'doc':
      case 'odt':
      case 'ods':
        return FilePreviewCategory.binary;
      default:
        if (_videoExtensions.contains(ext)) {
          return FilePreviewCategory.video;
        }
        if (_audioExtensions.contains(ext)) {
          return FilePreviewCategory.audio;
        }
        break;
    }

    final mime = lookupMimeType(fileName)?.toLowerCase();
    if (mime != null) {
      if (mime == 'application/pdf') return FilePreviewCategory.pdf;
      if (mime.startsWith('video/')) return FilePreviewCategory.video;
      if (mime.startsWith('audio/')) return FilePreviewCategory.audio;
      if (mime ==
              'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' ||
          mime == 'application/vnd.ms-excel') {
        return ext == 'xls'
            ? FilePreviewCategory.binary
            : FilePreviewCategory.spreadsheet;
      }
      if (mime ==
          'application/vnd.openxmlformats-officedocument.wordprocessingml.document') {
        return FilePreviewCategory.document;
      }
      if (mime ==
              'application/vnd.openxmlformats-officedocument.presentationml.presentation' ||
          mime == 'application/vnd.ms-powerpoint' ||
          mime == 'application/vnd.oasis.opendocument.presentation') {
        return FilePreviewCategory.presentation;
      }
      if (mime.startsWith('text/') ||
          mime == 'application/json' ||
          mime == 'application/xml') {
        return FilePreviewCategory.text;
      }
      if (mime == 'application/x-msdownload' ||
          mime == 'application/x-executable' ||
          mime == 'application/vnd.microsoft.portable-executable') {
        return FilePreviewCategory.blocked;
      }
    }

    return FilePreviewCategory.binary;
  }

  static bool isLegacyPresentation(String fileName) {
    final ext = p.extension(fileName).toLowerCase().replaceFirst('.', '');
    return ext == 'ppt' || ext == 'odp';
  }

  static bool supportsInlinePreview(FilePreviewCategory category) {
    return switch (category) {
      FilePreviewCategory.text ||
      FilePreviewCategory.pdf ||
      FilePreviewCategory.spreadsheet ||
      FilePreviewCategory.document ||
      FilePreviewCategory.presentation ||
      FilePreviewCategory.video ||
      FilePreviewCategory.audio =>
        true,
      _ => false,
    };
  }

  static bool requiresDownloadWarning(FilePreviewCategory category) {
    return category == FilePreviewCategory.blocked;
  }

  static bool exceedsPreviewLimit(int byteLength) {
    return byteLength > maxPreviewBytes;
  }

  static String? mimeTypeFor(String fileName) {
    return lookupMimeType(fileName);
  }
}
