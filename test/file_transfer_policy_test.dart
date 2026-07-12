import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/util/file_transfer_policy.dart';

void main() {
  test('shouldUseChunkedTransfer requires threshold, ws, and peer support', () {
    expect(
      FileTransferPolicy.shouldUseChunkedTransfer(
        fileSizeBytes: FileTransferPolicy.chunkThresholdBytes,
        wsConnected: true,
        peerSupportsFileTransfer: true,
      ),
      isTrue,
    );
    expect(
      FileTransferPolicy.shouldUseChunkedTransfer(
        fileSizeBytes: FileTransferPolicy.chunkThresholdBytes - 1,
        wsConnected: true,
        peerSupportsFileTransfer: true,
      ),
      isFalse,
    );
    expect(
      FileTransferPolicy.shouldUseChunkedTransfer(
        fileSizeBytes: FileTransferPolicy.chunkThresholdBytes,
        wsConnected: false,
        peerSupportsFileTransfer: true,
      ),
      isFalse,
    );
    expect(
      FileTransferPolicy.shouldUseChunkedTransfer(
        fileSizeBytes: FileTransferPolicy.chunkThresholdBytes,
        wsConnected: true,
        peerSupportsFileTransfer: false,
      ),
      isFalse,
    );
  });

  test('chunkCountForSize rounds up', () {
    expect(FileTransferPolicy.chunkCountForSize(1), 1);
    expect(
      FileTransferPolicy.chunkCountForSize(FileTransferPolicy.chunkSizeBytes + 1),
      2,
    );
  });

  test('isWithinMaxFileSize enforces 50 MiB cap', () {
    expect(
      FileTransferPolicy.isWithinMaxFileSize(FileTransferPolicy.maxFileSizeBytes),
      isTrue,
    );
    expect(
      FileTransferPolicy.isWithinMaxFileSize(
        FileTransferPolicy.maxFileSizeBytes + 1,
      ),
      isFalse,
    );
  });

  test('shouldAvoidWsMonolithicSend for large media only', () {
    expect(
      FileTransferPolicy.shouldAvoidWsMonolithicSend({
        'type': 'file',
        'fileSize': FileTransferPolicy.chunkThresholdBytes,
        'message': 'x',
      }),
      isTrue,
    );
    expect(
      FileTransferPolicy.shouldAvoidWsMonolithicSend({
        'type': 'text',
        'message': 'x' * FileTransferPolicy.chunkThresholdBytes,
      }),
      isFalse,
    );
    expect(
      FileTransferPolicy.shouldAvoidWsMonolithicSend({
        'type': 'image',
        'message': 'x' * FileTransferPolicy.chunkThresholdBytes,
      }),
      isTrue,
    );
  });
}
