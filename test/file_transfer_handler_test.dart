import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/crypto/envelope.dart';
import 'package:prysm/server/inbound_message_router.dart';
import 'package:prysm/services/file_transfer_handler.dart';
import 'package:prysm/services/file_transfer_progress.dart';
import 'package:prysm/services/settings_service.dart';
import 'package:prysm/transport/ws_protocol.dart';
import 'package:prysm/util/file_transfer_policy.dart';
import 'package:prysm/util/key_manager.dart';

class _TestRouter extends InboundMessageRouter {
  _TestRouter()
      : super(
          keyManager: KeyManager(),
          settings: SettingsService(),
          localOnionAddress: () => 'local.onion',
        );

  Map<String, dynamic>? lastProcessed;

  @override
  Future<InboundHandleResult> processMessage(
    Map<String, dynamic> data,
  ) async {
    lastProcessed = data;
    return InboundHandleResult.ok({'ok': true});
  }
}

void main() {
  setUp(() {
    FileTransferHandler.instance.resetForTest();
    FileTransferProgress.resetForTest();
  });

  test('handleBegin and chunks reassemble ciphertext', () async {
    final handler = FileTransferHandler.instance;
    final transferId = '550e8400-e29b-41d4-a716-446655440000';
    final ciphertext = Uint8List.fromList(List<int>.generate(300, (i) => i % 251));
    final chunkSize = FileTransferPolicy.chunkSizeBytes;
    final totalChunks = FileTransferPolicy.chunkCountForSize(ciphertext.length);

    final beginResult = await handler.handleBegin(
      {
        'transferId': transferId,
        'messageId': 'msg-1',
        'senderId': 'peer.onion',
        'receiverId': 'local.onion',
        'type': 'file',
        'fileName': 'test.bin',
        'fileSize': 300,
        'timestamp': 1,
        'wrappedKey': {'ephemeralPub': 'abc'},
        'nonce': base64Encode(Uint8List(12)),
        'ciphertextSize': ciphertext.length,
        'totalChunks': totalChunks,
        'chunkSize': chunkSize,
      },
      peerOnion: 'peer.onion',
      localOnion: 'local.onion',
    );
    expect(beginResult['ok'], isTrue);

    for (var i = 0; i < totalChunks; i++) {
      final offset = i * chunkSize;
      final end = offset + chunkSize > ciphertext.length
          ? ciphertext.length
          : offset + chunkSize;
      final frame = FileTransferChunkFrame(
        transferId: transferId,
        chunkIndex: i,
        payload: ciphertext.sublist(offset, end),
      );
      await handler.handleChunk(
        frame,
        peerOnion: 'peer.onion',
        sendAck: (_, {payload}) async {},
      );
    }

    final testRouter = _TestRouter();
    handler.routerOverride = testRouter;

    final endResult = await handler.handleEnd(
      {'transferId': transferId},
      peerOnion: 'peer.onion',
    );
    expect(endResult['ok'], isTrue);
    expect(testRouter.lastProcessed?['id'], 'msg-1');
    expect(testRouter.lastProcessed?['type'], 'file');

    final wire = testRouter.lastProcessed?['message'] as String;
    final envelope = CryptoEnvelope.tryParse(wire);
    expect(envelope, isNotNull);
    final decodedCipher = base64Decode(envelope!['ciphertext'] as String);
    expect(decodedCipher, ciphertext);
  });

  test('handleEnd rejects incomplete transfer', () async {
    final handler = FileTransferHandler.instance;
    const transferId = '550e8400-e29b-41d4-a716-446655440001';

    await handler.handleBegin(
      {
        'transferId': transferId,
        'messageId': 'msg-2',
        'senderId': 'peer.onion',
        'receiverId': 'local.onion',
        'type': 'file',
        'fileName': 'test.bin',
        'fileSize': 10,
        'timestamp': 1,
        'wrappedKey': {'ephemeralPub': 'abc'},
        'nonce': base64Encode(Uint8List(12)),
        'ciphertextSize': 10,
        'totalChunks': 1,
        'chunkSize': FileTransferPolicy.chunkSizeBytes,
      },
      peerOnion: 'peer.onion',
      localOnion: 'local.onion',
    );

    final endResult = await handler.handleEnd(
      {'transferId': transferId},
      peerOnion: 'peer.onion',
    );
    expect(endResult['error'], 'Incomplete transfer');
  });
}
