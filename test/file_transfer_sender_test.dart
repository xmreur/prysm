import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/crypto/envelope.dart';
import 'package:prysm/services/file_transfer_progress.dart';
import 'package:prysm/services/file_transfer_sender.dart';
import 'package:prysm/services/ws_connection_manager.dart';
import 'package:prysm/transport/ws_peer_link.dart';
import 'package:prysm/transport/ws_protocol.dart';
import 'package:prysm/util/file_transfer_policy.dart';
import 'package:prysm/util/tor_lifecycle_state.dart';
import 'package:prysm/util/tor_runtime_gate.dart';
import 'package:prysm/util/tor_service.dart';

class _ChunkAckLink implements WsPeerLink {
  _ChunkAckLink(this.peerOnion);

  @override
  final String peerOnion;

  final pushController = StreamController<Map<String, dynamic>>.broadcast();
  final sentBinary = <List<int>>[];
  final sentOps = <String>[];
  final sentPayloads = <Map<String, dynamic>?>[];

  @override
  bool isConnected = true;

  @override
  Stream<List<int>> get onBinaryFrames => const Stream.empty();

  @override
  Stream<Map<String, dynamic>> get onPushFrames => pushController.stream;

  @override
  Future<void> close() async {
    isConnected = false;
  }

  @override
  Future<Map<String, dynamic>> request(
    String op, {
    Map<String, dynamic>? payload,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    sentOps.add(op);
    sentPayloads.add(payload);
    if (op == 'file_transfer_begin' && payload != null) {
      return {
        'ok': true,
        'transferId': payload['transferId'],
      };
    }
    if (op == 'file_transfer_end' && payload != null) {
      return {
        'ok': true,
        'transferId': payload['transferId'],
      };
    }
    return {'ok': true};
  }

  @override
  Future<void> send(String op, {Map<String, dynamic>? payload}) async {
    sentOps.add(op);
    sentPayloads.add(payload);
  }

  @override
  Future<void> sendBytes(List<int> bytes) async {
    sentBinary.add(bytes);
    final frame = FileTransferChunkFrame.decode(bytes);
    pushController.add({
      'op': 'file_transfer_chunk_ack',
      'payload': {
        'transferId': frame.transferId,
        'chunkIndex': frame.chunkIndex,
      },
    });
  }

  @override
  Future<void> sendPing() async {}
}

void main() {
  setUp(() {
    TorRuntimeGate.resetForTest();
    TorLifecycleNotifier.instance.update(TorLifecycleState.ready);
  });

  test('sender splits ciphertext and reports progress', () async {
    FileTransferProgress.resetForTest();

    final ciphertext =
        Uint8List.fromList(List<int>.generate(300000, (i) => i % 251));
    final envelope = CryptoEnvelope.fileAead1(
      wrappedKey: {'ephemeralPub': 'abc'},
      nonce: Uint8List(12),
      ciphertext: ciphertext,
    );
    final peerPayload = CryptoEnvelope.encode(envelope);

    final manager = WsConnectionManager(
      TorManager(torPath: '/bin/false', dataDir: '/tmp/file-transfer-sender'),
    );
    final link = _ChunkAckLink('peer.onion');
    manager.registerLinkForTest('peer.onion', link);

    final sender = FileTransferSender(manager);
    final ok = await sender.send(
      peerOnion: 'peer.onion',
      messageId: 'msg-1',
      senderId: 'me.onion',
      receiverId: 'peer.onion',
      type: 'file',
      fileName: 'big.bin',
      fileSize: ciphertext.length,
      peerPayload: peerPayload,
    );

    expect(ok, isTrue);
    expect(link.sentOps, contains('file_transfer_begin'));
    expect(link.sentOps, contains('file_transfer_end'));
    expect(
      link.sentBinary.length,
      FileTransferPolicy.chunkCountForSize(ciphertext.length),
    );
    expect(FileTransferProgress.uploadFor('msg-1')?.value, 1.0);

    manager.dispose();
  });
}
