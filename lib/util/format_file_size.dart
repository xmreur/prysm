/// Formats a byte count for display (KB / MB).
String formatFileSize(int bytes) {
  if (bytes < 0) return '0 B';
  if (bytes < 1024) return '$bytes B';
  final sizeInKB = bytes / 1024;
  if (sizeInKB < 1024) {
    return '${sizeInKB.toStringAsFixed(1)} KB';
  }
  return '${(sizeInKB / 1024).toStringAsFixed(1)} MB';
}
