/// Thresholds and sizing for chunked WebSocket file transfer.
class FileTransferPolicy {
  FileTransferPolicy._();

  /// Files at or above this size use chunked WS transfer when supported.
  static const int chunkThresholdBytes = 1024 * 1024; // 1 MiB

  /// Maximum outbound attachment size.
  static const int maxFileSizeBytes = 50 * 1024 * 1024; // 50 MiB

  static const String maxFileSizeLabel = '50 MB';

  static String get maxFileSizeError =>
      'Files larger than $maxFileSizeLabel cannot be sent.';

  static bool isWithinMaxFileSize(int bytes) => bytes <= maxFileSizeBytes;

  /// Raw ciphertext bytes per WS binary chunk.
  static const int chunkSizeBytes = 256 * 1024; // 256 KiB

  /// Abandon in-progress inbound transfers after this idle period.
  static const Duration transferTtl = Duration(minutes: 10);

  /// Per-chunk send retries before failing the transfer.
  static const int maxChunkRetries = 3;

  static bool shouldUseChunkedTransfer({
    required int fileSizeBytes,
    required bool wsConnected,
    required bool peerSupportsFileTransfer,
  }) {
    if (fileSizeBytes < chunkThresholdBytes) return false;
    if (!wsConnected) return false;
    return peerSupportsFileTransfer;
  }

  static int chunkCountForSize(int byteSize) {
    if (byteSize <= 0) return 0;
    return (byteSize + chunkSizeBytes - 1) ~/ chunkSizeBytes;
  }

  /// Large media must use chunked WS or HTTP — not monolithic WS frames.
  static bool shouldAvoidWsMonolithicSend(Map<String, dynamic> payload) {
    final type = payload['type'];
    if (type != 'file' && type != 'image' && type != 'audio') {
      return false;
    }
    final fileSize = payload['fileSize'];
    if (fileSize is int && fileSize >= chunkThresholdBytes) {
      return true;
    }
    final message = payload['message'];
    if (message is String && message.length >= chunkThresholdBytes) {
      return true;
    }
    return false;
  }
}
