import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/server/inbound_limits.dart';
import 'package:prysm/services/file_transfer_handler.dart';
import 'package:prysm/services/file_transfer_progress.dart';
import 'package:prysm/util/file_transfer_policy.dart';

/// Mirrors the begin-frame shape the real sender produces — see
/// file_transfer_sender.dart and test/file_transfer_handler_test.dart.
Map<String, dynamic> beginPayload({
  required int fileSize,
  int? ciphertextSize,
  int? chunkSize,
  int? totalChunks,
}) {
  final ciphertext = ciphertextSize ?? fileSize + 16;
  final chunk = chunkSize ?? FileTransferPolicy.chunkSizeBytes;
  final chunks = totalChunks ?? FileTransferPolicy.chunkCountForSize(ciphertext);
  return {
    'transferId': 'test-transfer',
    'messageId': 'msg-1',
    'senderId': 'peer.onion',
    'receiverId': 'local.onion',
    'type': 'file',
    'fileName': 'test.bin',
    'fileSize': fileSize,
    'timestamp': 1,
    'wrappedKey': {'ephemeralPub': 'abc'},
    'nonce': base64Encode(Uint8List(12)),
    'ciphertextSize': ciphertext,
    'totalChunks': chunks,
    'chunkSize': chunk,
  };
}

void main() {
  setUp(() {
    FileTransferHandler.instance.resetForTest();
    FileTransferProgress.resetForTest();
  });

  group('FileTransferHandler.validateBegin size caps', () {
    Map<String, dynamic>? validate(Map<String, dynamic> payload) {
      return FileTransferHandler.instance.validateBegin(
        payload,
        peerOnion: 'peer.onion',
        localOnion: 'local.onion',
      );
    }

    test('accepts a well-formed 1 MiB transfer', () {
      const fileSize = 1024 * 1024;
      final error = validate(beginPayload(fileSize: fileSize));
      expect(error, isNull);
    });

    test('rejects a ciphertextSize that would allocate gigabytes', () {
      final error = validate(
        beginPayload(fileSize: 1024 * 1024, ciphertextSize: 8000000000),
      );
      expect(error, isNotNull);
      expect(error!['error'], 'Ciphertext too large');
    });

    test('rejects chunkSize above FileTransferPolicy.chunkSizeBytes', () {
      final error = validate(
        beginPayload(
          fileSize: 1024 * 1024,
          chunkSize: FileTransferPolicy.chunkSizeBytes + 1,
        ),
      );
      expect(error, isNotNull);
      expect(error!['error'], 'Invalid chunk metadata');
    });

    test('rejects totalChunks inconsistent with the declared sizes', () {
      final error = validate(
        beginPayload(
          fileSize: 1024 * 1024,
          totalChunks: FileTransferPolicy.chunkCountForSize(1024 * 1024 + 16) + 1,
        ),
      );
      expect(error, isNotNull);
      expect(error!['error'], 'Invalid chunk metadata');
    });

    test('rejects fileSize above FileTransferPolicy.maxFileSizeBytes', () {
      final error = validate(
        beginPayload(fileSize: FileTransferPolicy.maxFileSizeBytes + 1),
      );
      expect(error, isNotNull);
      expect(error!['error'], 'File too large');
    });

    test('rejects a non-int fileSize', () {
      final error = validate(
        beginPayload(fileSize: 1024 * 1024)..['fileSize'] = 'huge',
      );
      expect(error, isNotNull);
      expect(error!['error'], 'File too large');
    });

    test('rejects a new begin once concurrent transfers are at the cap', () async {
      final handler = FileTransferHandler.instance;
      for (var i = 0; i < InboundLimits.maxConcurrentInboundTransfers; i++) {
        final result = await handler.handleBegin(
          beginPayload(fileSize: 300)..['transferId'] = 't-$i',
          peerOnion: 'peer.onion',
          localOnion: 'local.onion',
        );
        expect(result['ok'], isTrue);
      }

      final result = await handler.handleBegin(
        beginPayload(fileSize: 300),
        peerOnion: 'peer.onion',
        localOnion: 'local.onion',
      );
      expect(result['error'], 'Too many transfers');
    });
  });

  group('InboundLimits.readCapped', () {
    test('returns the bytes for a stream under the cap', () async {
      final body = Stream<List<int>>.fromIterable([
        [1, 2, 3],
        [4, 5, 6],
      ]);
      final bytes = await InboundLimits.readCapped(body, 10);
      expect(bytes, [1, 2, 3, 4, 5, 6]);
    });

    test('throws before fully draining a stream that exceeds the cap', () async {
      var chunksYielded = 0;
      final body = Stream<List<int>>.fromIterable([
        List<int>.filled(10, 1),
        List<int>.filled(10, 2),
        List<int>.filled(10, 3),
      ]).map((chunk) {
        chunksYielded++;
        return chunk;
      });

      await expectLater(
        InboundLimits.readCapped(body, 15),
        throwsA(isA<PayloadTooLargeException>()),
      );

      // The cap must bite while streaming: the third chunk (which would push
      // the total past 15) must never be pulled from the source.
      expect(chunksYielded, lessThan(3));
    });
  });
}
