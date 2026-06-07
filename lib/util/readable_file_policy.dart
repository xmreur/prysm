import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;

enum FilePreviewCategory {
  text,
  pdf,
  spreadsheet,
  document,
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
        return FilePreviewCategory.binary;
      default:
        break;
    }

    final mime = lookupMimeType(fileName)?.toLowerCase();
    if (mime != null) {
      if (mime == 'application/pdf') return FilePreviewCategory.pdf;
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

  static bool supportsInlinePreview(FilePreviewCategory category) {
    return switch (category) {
      FilePreviewCategory.text ||
      FilePreviewCategory.pdf ||
      FilePreviewCategory.spreadsheet ||
      FilePreviewCategory.document =>
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
}
