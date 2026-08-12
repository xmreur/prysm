import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/crypto/constants.dart';
import 'package:prysm/crypto/envelope.dart';
import 'package:prysm/crypto/identity.dart';
import 'package:prysm/crypto/wire.dart';
import 'package:prysm/server/inbound_message_router.dart';
import 'package:prysm/services/file_transfer_handler.dart';
import 'package:prysm/services/file_transfer_progress.dart';
import 'package:prysm/services/file_transfer_sender.dart';
import 'package:prysm/services/settings_service.dart';
import 'package:prysm/services/ws_connection_manager.dart';
import 'package:prysm/transport/ws_peer_link.dart';
import 'package:prysm/transport/ws_protocol.dart';
import 'package:prysm/util/file_transfer_policy.dart';
import 'package:prysm/util/key_manager.dart';
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

Future<IdentityPublicKeys> _publicKeys(IdentityKeyPair id) async {
  final sign = await id.signPublicKey;
  final agree = await id.agreePublicKey;
  return IdentityPublicKeys(
    signPublic: sign,
    agreePublic: agree,
    fingerprint: IdentityKeyPair.fingerprintFromPublicJson(
      await id.toPublicJson(),
    ),
  );
}

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

Map<String, dynamic> _beginPayload({
  required String transferId,
  required String messageId,
  required String senderId,
  required String receiverId,
  required Uint8List ciphertext,
  String? scheme,
  Map<String, dynamic>? wrappedKey,
}) {
  return {
    'transferId': transferId,
    'messageId': messageId,
    'senderId': senderId,
    'receiverId': receiverId,
    'type': 'file',
    'fileName': 'test.bin',
    'fileSize': 300,
    'timestamp': 1,
    'scheme': ?scheme,
    'wrappedKey': wrappedKey ?? {'ephemeralPub': 'abc'},
    'nonce': base64Encode(Uint8List(12)),
    'ciphertextSize': ciphertext.length,
    'totalChunks': FileTransferPolicy.chunkCountForSize(ciphertext.length),
    'chunkSize': FileTransferPolicy.chunkSizeBytes,
  };
}

Future<void> _deliverChunks(
  FileTransferHandler handler,
  String transferId,
  Uint8List ciphertext, {
  required String peerOnion,
}) async {
  final chunkSize = FileTransferPolicy.chunkSizeBytes;
  for (var i = 0; i < FileTransferPolicy.chunkCountForSize(ciphertext.length); i++) {
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
      peerOnion: peerOnion,
      sendAck: (_, {payload}) async {},
    );
  }
}

void main() {
  setUp(() {
    TorRuntimeGate.resetForTest();
    TorLifecycleNotifier.instance.update(TorLifecycleState.ready);
    FileTransferHandler.instance.resetForTest();
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
      TorManager(torPath: '/bin/false', dataDir: '/tmp/file-transfer-sender', controlPassword: 'test-password'),
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

  test(
    'parseFileTransferParts accepts the real encryptFile signed payload',
    () async {
      final alice = await IdentityKeyPair.generate();
      final bob = await IdentityKeyPair.generate();
      final bobPub = await bob.agreePublicKey;
      final bytes =
          Uint8List.fromList(List<int>.generate(300, (i) => i % 251));

      final payloads = await CryptoWire.encryptFile(bytes, alice, bobPub);

      final parts = parseFileTransferParts(payloads.peerPayload);
      expect(parts.scheme, CryptoConstants.schemeFileSigned1);
      expect(parts.wrappedKey['sig'], isA<String>());
      expect(parts.ciphertext.length, greaterThan(0));
    },
  );

  test(
    'sender sends a real signed payload and its reassembly decrypts '
    'like the monolithic envelope',
    () async {
      FileTransferProgress.resetForTest();

      final alice = await IdentityKeyPair.generate();
      final bob = await IdentityKeyPair.generate();
      final bobPub = await bob.agreePublicKey;
      final alicePub = await _publicKeys(alice);
      final bytes =
          Uint8List.fromList(List<int>.generate(300, (i) => i % 251));

      final payloads = await CryptoWire.encryptFile(bytes, alice, bobPub);

      final manager = WsConnectionManager(
        TorManager(torPath: '/bin/false', dataDir: '/tmp/file-transfer-sender', controlPassword: 'test-password'),
      );
      final link = _ChunkAckLink('peer.onion');
      manager.registerLinkForTest('peer.onion', link);

      final sender = FileTransferSender(manager);
      final ok = await sender.send(
        peerOnion: 'peer.onion',
        messageId: 'msg-signed-1',
        senderId: 'me.onion',
        receiverId: 'peer.onion',
        type: 'file',
        fileName: 'signed.bin',
        fileSize: bytes.length,
        peerPayload: payloads.peerPayload,
      );
      expect(ok, isTrue);

      final beginIndex = link.sentOps.indexOf('file_transfer_begin');
      expect(beginIndex, isNonNegative);
      final beginPayload = link.sentPayloads[beginIndex]!;
      expect(beginPayload['scheme'], CryptoConstants.schemeFileSigned1);
      expect(
        (beginPayload['wrappedKey'] as Map<String, dynamic>)['sig'],
        isA<String>(),
      );

      // Feed the sender's exact wire output into the receiver path; the
      // reassembled transfer must be rebuilt as file-signed-1 and decrypt
      // exactly like the monolithic peer payload.
      final handler = FileTransferHandler.instance;
      final beginResult = await handler.handleBegin(
        beginPayload,
        peerOnion: 'me.onion',
        localOnion: 'peer.onion',
      );
      expect(beginResult['ok'], isTrue);

      for (final raw in link.sentBinary) {
        final frame = FileTransferChunkFrame.decode(raw);
        await handler.handleChunk(
          frame,
          peerOnion: 'me.onion',
          sendAck: (_, {payload}) async {},
        );
      }

      final testRouter = _TestRouter();
      handler.routerOverride = testRouter;
      final endResult = await handler.handleEnd(
        {'transferId': beginPayload['transferId'] as String},
        peerOnion: 'me.onion',
      );
      expect(endResult['ok'], isTrue);

      final wire = testRouter.lastProcessed?['message'] as String;
      final envelope = CryptoEnvelope.tryParse(wire);
      expect(envelope, isNotNull);
      expect(envelope!['scheme'], CryptoConstants.schemeFileSigned1);

      final dec = await CryptoWire.decryptFileFromPeer(wire, bob, alicePub);
      expect(dec, bytes);

      manager.dispose();
    },
  );

  test('handleEnd rebuilds file-signed-1 when begin carries the scheme',
      () async {
    final handler = FileTransferHandler.instance;
    const transferId = '550e8400-e29b-41d4-a716-4466554400aa';
    final ciphertext =
        Uint8List.fromList(List<int>.generate(300, (i) => i % 251));

    final beginResult = await handler.handleBegin(
      _beginPayload(
        transferId: transferId,
        messageId: 'msg-rebuild-signed',
        senderId: 'peer.onion',
        receiverId: 'local.onion',
        ciphertext: ciphertext,
        scheme: CryptoConstants.schemeFileSigned1,
        wrappedKey: {
          'crypto': CryptoConstants.cryptoVersion,
          'scheme': CryptoConstants.schemeDmSigned2,
          'ephemeralPub': 'abc',
          'nonce': base64Encode(Uint8List(12)),
          'ciphertext': base64Encode(Uint8List(16)),
          'sig': 'c2ln',
        },
      ),
      peerOnion: 'peer.onion',
      localOnion: 'local.onion',
    );
    expect(beginResult['ok'], isTrue);

    await _deliverChunks(
      handler,
      transferId,
      ciphertext,
      peerOnion: 'peer.onion',
    );

    final testRouter = _TestRouter();
    handler.routerOverride = testRouter;
    final endResult = await handler.handleEnd(
      {'transferId': transferId},
      peerOnion: 'peer.onion',
    );
    expect(endResult['ok'], isTrue);

    final wire = testRouter.lastProcessed?['message'] as String;
    final envelope = CryptoEnvelope.tryParse(wire);
    expect(envelope, isNotNull);
    expect(envelope!['scheme'], CryptoConstants.schemeFileSigned1);
  });

  test('handleEnd rebuilds file-aead-1 when begin has no scheme (legacy peer)',
      () async {
    final handler = FileTransferHandler.instance;
    const transferId = '550e8400-e29b-41d4-a716-4466554400bb';
    final ciphertext =
        Uint8List.fromList(List<int>.generate(300, (i) => i % 251));

    final beginResult = await handler.handleBegin(
      _beginPayload(
        transferId: transferId,
        messageId: 'msg-rebuild-legacy',
        senderId: 'peer.onion',
        receiverId: 'local.onion',
        ciphertext: ciphertext,
      ),
      peerOnion: 'peer.onion',
      localOnion: 'local.onion',
    );
    expect(beginResult['ok'], isTrue);

    await _deliverChunks(
      handler,
      transferId,
      ciphertext,
      peerOnion: 'peer.onion',
    );

    final testRouter = _TestRouter();
    handler.routerOverride = testRouter;
    final endResult = await handler.handleEnd(
      {'transferId': transferId},
      peerOnion: 'peer.onion',
    );
    expect(endResult['ok'], isTrue);

    final wire = testRouter.lastProcessed?['message'] as String;
    final envelope = CryptoEnvelope.tryParse(wire);
    expect(envelope, isNotNull);
    expect(envelope!['scheme'], CryptoConstants.schemeFileAead1);
  });

  test(
      'handleEnd rebuilds file-aead-1 when begin carries an unrecognized '
      'scheme',
      () async {
    final handler = FileTransferHandler.instance;
    const transferId = '550e8400-e29b-41d4-a716-4466554400cc';
    final ciphertext =
        Uint8List.fromList(List<int>.generate(300, (i) => i % 251));

    final beginResult = await handler.handleBegin(
      _beginPayload(
        transferId: transferId,
        messageId: 'msg-rebuild-unknown',
        senderId: 'peer.onion',
        receiverId: 'local.onion',
        ciphertext: ciphertext,
        scheme: 'file-signed-99',
      ),
      peerOnion: 'peer.onion',
      localOnion: 'local.onion',
    );
    expect(beginResult['ok'], isTrue);

    await _deliverChunks(
      handler,
      transferId,
      ciphertext,
      peerOnion: 'peer.onion',
    );

    final testRouter = _TestRouter();
    handler.routerOverride = testRouter;
    final endResult = await handler.handleEnd(
      {'transferId': transferId},
      peerOnion: 'peer.onion',
    );
    expect(endResult['ok'], isTrue);

    final wire = testRouter.lastProcessed?['message'] as String;
    final envelope = CryptoEnvelope.tryParse(wire);
    expect(envelope, isNotNull);
    expect(envelope!['scheme'], CryptoConstants.schemeFileAead1);
  });
}
