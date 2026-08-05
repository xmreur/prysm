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

  group('InboundLimits.readCapped shared in-flight budget', () {
    test(
        'refuses a second concurrent read once the budget is exhausted and '
        'stops pulling from its source, then recovers when the first read '
        'releases', () async {
      final budget = InboundBodyBudget(maxBytes: 100);

      // Read 1 holds its first chunk (60 bytes) and keeps the connection
      // open: the budget must count bytes held, not requests started.
      final firstController = StreamController<List<int>>();
      var firstChunks = 0;
      final firstRead = InboundLimits.readCapped(
        firstController.stream.map((chunk) {
          firstChunks++;
          return chunk;
        }),
        200,
        budget: budget,
      );

      firstController.add(List<int>.filled(60, 1));
      // Yield to the event loop so read 1 has consumed (and reserved) its
      // first chunk before read 2 starts.
      await Future<void>.delayed(Duration.zero);
      expect(budget.inFlightBytes, 60);

      // Read 2 is refused on its first chunk (60 + 60 > 100): distinct from
      // an oversized body, and its source must not be drained further.
      var secondChunks = 0;
      await expectLater(
        InboundLimits.readCapped(
          Stream<List<int>>.fromIterable([
            List<int>.filled(60, 2),
            List<int>.filled(60, 3),
          ]).map((chunk) {
            secondChunks++;
            return chunk;
          }),
          200,
          budget: budget,
        ),
        throwsA(isA<ServerBusyException>()),
      );
      expect(secondChunks, 1);

      // Closing read 1 releases its reservation (leak check: this fails if
      // the finally-release is removed) ...
      firstController.add(List<int>.filled(40, 4));
      await firstController.close();
      await expectLater(firstRead, completion(hasLength(100)));
      expect(firstChunks, 2);
      expect(budget.inFlightBytes, 0);

      // ... and a subsequent read succeeds: the budget is not wedged.
      final third = await InboundLimits.readCapped(
        Stream<List<int>>.fromIterable([
          List<int>.filled(90, 5),
        ]),
        200,
        budget: budget,
      );
      expect(third, hasLength(90));
      expect(budget.inFlightBytes, 0);
    });

    test('a read that throws PayloadTooLargeException releases its '
        'reservation', () async {
      final budget = InboundBodyBudget(maxBytes: 200);

      // Per-body cap (100) trips before the budget (200): the reserved 120
      // bytes must still be released by the finally block.
      final body = Stream<List<int>>.fromIterable([
        List<int>.filled(60, 1),
        List<int>.filled(60, 2),
      ]);

      await expectLater(
        InboundLimits.readCapped(body, 100, budget: budget),
        throwsA(isA<PayloadTooLargeException>()),
      );
      expect(budget.inFlightBytes, 0);
    });
  });
}
