import 'package:flutter/foundation.dart';

/// Tracks upload/download progress for in-flight file transfers by message id.
class FileTransferProgress {
  FileTransferProgress._();

  static final Map<String, ValueNotifier<double>> _upload = {};
  static final Map<String, ValueNotifier<double>> _download = {};

  static ValueNotifier<double>? uploadFor(String messageId) => _upload[messageId];

  static ValueNotifier<double>? downloadFor(String messageId) => _download[messageId];

  static ValueNotifier<double> uploadNotifier(String messageId) {
    return _upload.putIfAbsent(messageId, () => ValueNotifier(0));
  }

  static ValueNotifier<double> downloadNotifier(String messageId) {
    return _download.putIfAbsent(messageId, () => ValueNotifier(0));
  }

  static void setUpload(String messageId, double value) {
    uploadNotifier(messageId).value = value.clamp(0.0, 1.0);
  }

  static void setDownload(String messageId, double value) {
    downloadNotifier(messageId).value = value.clamp(0.0, 1.0);
  }

  static void clearUpload(String messageId) {
    _upload.remove(messageId)?.dispose();
  }

  static void clearDownload(String messageId) {
    _download.remove(messageId)?.dispose();
  }

  static void clearAll() {
    for (final notifier in _upload.values) {
      notifier.dispose();
    }
    for (final notifier in _download.values) {
      notifier.dispose();
    }
    _upload.clear();
    _download.clear();
  }

  @visibleForTesting
  static void resetForTest() => clearAll();
}
