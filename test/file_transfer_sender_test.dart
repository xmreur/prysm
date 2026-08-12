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

/// A link that records every chunk frame but does NOT ack it until the test
/// releases the ack, so a windowed sender can be observed mid-flight (unlike
/// [_ChunkAckLink], whose synchronous acks hide any pipelining).
class _GatedAckLink implements WsPeerLink {
  _GatedAckLink(this.peerOnion, {this.throwOnSendIndex});

  @override
  final String peerOnion;

  /// When set, [sendBytes] throws for the matching chunk index instead of
  /// delivering the frame, simulating a failed write mid-transfer.
  final int? throwOnSendIndex;

  final pushController = StreamController<Map<String, dynamic>>.broadcast();
  final sentBinary = <List<int>>[];
  final sentOps = <String>[];
  final sentPayloads = <Map<String, dynamic>?>[];
  final pendingAcks = <Map<String, dynamic>>[];

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
    final frame = FileTransferChunkFrame.decode(bytes);
    if (frame.chunkIndex == throwOnSendIndex) {
      throw StateError('simulated send failure for chunk ${frame.chunkIndex}');
    }
    sentBinary.add(bytes);
    pendingAcks.add({
      'transferId': frame.transferId,
      'chunkIndex': frame.chunkIndex,
    });
  }

  List<int> sentChunkIndices() =>
      sentBinary.map((b) => FileTransferChunkFrame.decode(b).chunkIndex).toList();

  /// Pushes the first [count] queued acks (all of them when [count] is null).
  void releaseAcks([int? count]) {
    final acks = count == null
        ? List<Map<String, dynamic>>.from(pendingAcks)
        : pendingAcks.take(count).toList();
    for (final ack in acks) {
      pendingAcks.remove(ack);
      pushController.add({
        'op': 'file_transfer_chunk_ack',
        'payload': ack,
      });
    }
  }

  /// Pushes the first queued ack for [chunkIndex], if any.
  void releaseAckFor(int chunkIndex) {
    for (final ack in pendingAcks.toList()) {
      if (ack['chunkIndex'] == chunkIndex) {
        pendingAcks.remove(ack);
        pushController.add({
          'op': 'file_transfer_chunk_ack',
          'payload': ack,
        });
        return;
      }
    }
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

String _envelopePayload(Uint8List ciphertext) {
  final envelope = CryptoEnvelope.fileAead1(
    wrappedKey: {'ephemeralPub': 'abc'},
    nonce: Uint8List(12),
    ciphertext: ciphertext,
  );
  return CryptoEnvelope.encode(envelope);
}

/// Starts a chunked send against a gated link whose acks the test releases
/// manually, so a windowed driver can be observed mid-flight. [ackTimeout]
/// shortens the per-chunk ack wait so retry/abort paths can be driven fast.
({WsConnectionManager manager, _GatedAckLink link, Future<bool> send})
    _startGatedSend(
  Uint8List ciphertext, {
  required String messageId,
  Duration ackTimeout = const Duration(seconds: 60),
  int? throwOnSendIndex,
}) {
  final manager = WsConnectionManager(
    TorManager(
      torPath: '/bin/false',
      dataDir: '/tmp/file-transfer-sender',
      controlPassword: 'test-password',
    ),
  );
  final link = _GatedAckLink('peer.onion', throwOnSendIndex: throwOnSendIndex);
  manager.registerLinkForTest('peer.onion', link);
  final sender = FileTransferSender(manager, ackTimeout: ackTimeout);
  final send = sender.send(
    peerOnion: 'peer.onion',
    messageId: messageId,
    senderId: 'me.onion',
    receiverId: 'peer.onion',
    type: 'file',
    fileName: 'window.bin',
    fileSize: ciphertext.length,
    peerPayload: _envelopePayload(ciphertext),
  );
  return (manager: manager, link: link, send: send);
}

/// Polls [predicate] until it returns true or [timeout] elapses.
Future<void> _waitFor(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final end = DateTime.now().add(timeout);
  while (!predicate()) {
    if (DateTime.now().isAfter(end)) {
      fail('Timed out waiting for condition');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
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

  test('pipelines chunkWindowSize frames before any ack is released', () async {
    FileTransferProgress.resetForTest();
    final ciphertext = Uint8List.fromList(List<int>.generate(
      (FileTransferPolicy.chunkWindowSize + 2) *
          FileTransferPolicy.chunkSizeBytes,
      (i) => i % 251,
    ));
    final totalChunks = FileTransferPolicy.chunkCountForSize(ciphertext.length);
    expect(totalChunks, FileTransferPolicy.chunkWindowSize + 2);

    final started = _startGatedSend(ciphertext, messageId: 'msg-window-1');
    var ok = false;
    started.send.then((v) => ok = v);

    // The whole window is on the wire with no ack released.
    await _waitFor(
      () =>
          started.link.sentBinary.length ==
          FileTransferPolicy.chunkWindowSize,
    );
    expect(
      started.link.pendingAcks.length,
      FileTransferPolicy.chunkWindowSize,
    );

    // Releasing acks one at a time never leaves more than the window in
    // flight: every release lets exactly one refill chunk out.
    var released = 0;
    var maxInFlight = started.link.sentBinary.length;
    for (var i = 0; i < totalChunks; i++) {
      started.link.releaseAcks(1);
      released++;
      final expectedSent =
          totalChunks < FileTransferPolicy.chunkWindowSize + released
              ? totalChunks
              : FileTransferPolicy.chunkWindowSize + released;
      await _waitFor(() => started.link.sentBinary.length >= expectedSent);
      final inFlight = started.link.sentBinary.length - released;
      if (inFlight > maxInFlight) maxInFlight = inFlight;
    }
    await _waitFor(() => ok);
    expect(started.link.sentBinary.length, totalChunks);
    expect(
      maxInFlight,
      lessThanOrEqualTo(FileTransferPolicy.chunkWindowSize),
    );

    started.manager.dispose();
  });

  test('releasing one ack lets exactly one more chunk go out', () async {
    FileTransferProgress.resetForTest();
    final ciphertext = Uint8List.fromList(List<int>.generate(
      (FileTransferPolicy.chunkWindowSize + 2) *
          FileTransferPolicy.chunkSizeBytes,
      (i) => i % 251,
    ));

    final started = _startGatedSend(ciphertext, messageId: 'msg-window-2');
    var ok = false;
    started.send.then((v) => ok = v);

    await _waitFor(
      () =>
          started.link.sentBinary.length ==
          FileTransferPolicy.chunkWindowSize,
    );

    started.link.releaseAcks(1);
    await _waitFor(
      () =>
          started.link.sentBinary.length ==
          FileTransferPolicy.chunkWindowSize + 1,
    );

    started.link.releaseAcks(1);
    await _waitFor(
      () =>
          started.link.sentBinary.length ==
          FileTransferPolicy.chunkWindowSize + 2,
    );

    started.link.releaseAcks();
    await _waitFor(() => ok);
    expect(
      started.link.sentBinary.length,
      FileTransferPolicy.chunkCountForSize(ciphertext.length),
    );

    started.manager.dispose();
  });

  test('withheld ack makes the sender re-send only that index', () async {
    FileTransferProgress.resetForTest();
    final ciphertext = Uint8List.fromList(List<int>.generate(
      FileTransferPolicy.chunkWindowSize * FileTransferPolicy.chunkSizeBytes,
      (i) => i % 251,
    ));

    final started = _startGatedSend(
      ciphertext,
      messageId: 'msg-window-3',
      ackTimeout: const Duration(milliseconds: 500),
    );
    var ok = false;
    started.send.then((v) => ok = v);

    await _waitFor(
      () =>
          started.link.sentBinary.length ==
          FileTransferPolicy.chunkWindowSize,
    );

    // Ack every index except 3.
    for (var i = 0; i < FileTransferPolicy.chunkWindowSize; i++) {
      if (i != 3) started.link.releaseAckFor(i);
    }
    await _waitFor(() => started.link.pendingAcks.length == 1);

    // After the ack timeout only index 3 is re-sent, not the whole window.
    await _waitFor(
      () =>
          started.link.sentBinary.length ==
          FileTransferPolicy.chunkWindowSize + 1,
      timeout: const Duration(seconds: 5),
    );
    final indices = started.link.sentChunkIndices();
    expect(indices.length, FileTransferPolicy.chunkWindowSize + 1);
    expect(
      indices.sublist(FileTransferPolicy.chunkWindowSize),
      [3],
    );

    // Releasing the withheld ack completes the transfer. The sender drops
    // the ack key on every timeout and re-registers it on the next attempt,
    // and releaseAckFor silently no-ops when nothing is queued, so wait for
    // a queued ack first instead of racing the retry (a release landing in
    // the gap would be dropped and index 3 would exhaust maxChunkRetries).
    await _waitFor(
      () => started.link.pendingAcks.any((a) => a['chunkIndex'] == 3),
    );
    started.link.releaseAckFor(3);
    await _waitFor(() => ok);
    expect(started.link.sentOps, contains('file_transfer_end'));

    started.manager.dispose();
  });

  test('file_transfer_end waits for every index to be acked', () async {
    FileTransferProgress.resetForTest();
    final ciphertext = Uint8List.fromList(List<int>.generate(
      FileTransferPolicy.chunkWindowSize * FileTransferPolicy.chunkSizeBytes,
      (i) => i % 251,
    ));

    final started = _startGatedSend(ciphertext, messageId: 'msg-window-4');
    var ok = false;
    started.send.then((v) => ok = v);

    await _waitFor(
      () =>
          started.link.sentBinary.length ==
          FileTransferPolicy.chunkWindowSize,
    );

    // A full in-order prefix (indices 0..6) is acked while index 7 is not:
    // the sender must not request the end frame yet. Wait until the sender
    // has actually processed those acks (progress reaches 7/8) before
    // asserting, so a buggy "end after in-order prefix" would be caught.
    started.link.releaseAcks(FileTransferPolicy.chunkWindowSize - 1);
    await _waitFor(
      () =>
          (FileTransferProgress.uploadFor('msg-window-4')?.value ?? 0) ==
          (FileTransferPolicy.chunkWindowSize - 1) /
              FileTransferPolicy.chunkWindowSize,
    );
    expect(started.link.sentOps, isNot(contains('file_transfer_end')));

    // The final ack lets the end frame through.
    started.link.releaseAcks(1);
    await _waitFor(() => ok);
    expect(started.link.sentOps, contains('file_transfer_end'));

    started.manager.dispose();
  });

  test('an unacked index fails the transfer after maxChunkRetries', () async {
    FileTransferProgress.resetForTest();
    final ciphertext = Uint8List.fromList(List<int>.generate(
      FileTransferPolicy.chunkWindowSize * FileTransferPolicy.chunkSizeBytes,
      (i) => i % 251,
    ));

    final started = _startGatedSend(
      ciphertext,
      messageId: 'msg-window-5',
      ackTimeout: const Duration(milliseconds: 30),
    );
    var ok = true;
    started.send.then((v) => ok = v);

    await _waitFor(
      () =>
          started.link.sentBinary.length ==
          FileTransferPolicy.chunkWindowSize,
    );

    // Never ack anything: each index is retried until it exhausts
    // maxChunkRetries, then the whole transfer fails and send returns false.
    await _waitFor(() => ok == false, timeout: const Duration(seconds: 10));
    // A bound, not an exact count: the first index to exhaust its retries
    // completes transferFailed and send returns, so a slower chunk may never
    // send its third attempt, and a chunk sitting between attempts at that
    // moment can send one extra; with a 30 ms ackTimeout both are likely
    // under load. The upper bound (each index is sent at most
    // maxChunkRetries times) rules out retrying past the policy cap; the
    // lower bound (every index's first frame plus the exhausting index's
    // remaining attempts) rules out failing before one index has run
    // through all of its retries.
    expect(
      started.link.sentBinary.length,
      inInclusiveRange(
        FileTransferPolicy.chunkWindowSize +
            FileTransferPolicy.maxChunkRetries -
            1,
        FileTransferPolicy.chunkWindowSize * FileTransferPolicy.maxChunkRetries,
      ),
    );
    expect(started.link.sentOps, isNot(contains('file_transfer_end')));

    started.manager.dispose();
  });

  test('a sendBytes failure fails the transfer with no unhandled async error',
      () async {
    FileTransferProgress.resetForTest();
    final ciphertext = Uint8List.fromList(List<int>.generate(
      FileTransferPolicy.chunkWindowSize * FileTransferPolicy.chunkSizeBytes,
      (i) => i % 251,
    ));

    // Chunk 3's write fails on the wire. The ack completer for a chunk is
    // registered before sendBytes so an ack racing ahead of the send future
    // can still complete it; a throw used to leave that entry in the map for
    // send()'s finally to completeError on a future nobody listens to, which
    // the test zone reports as an uncaught async error. The transfer must
    // still fail (send returns false) without that leak.
    final started = _startGatedSend(
      ciphertext,
      messageId: 'msg-send-fails',
      throwOnSendIndex: 3,
    );

    expect(await started.send, isFalse);
    expect(started.link.sentOps, isNot(contains('file_transfer_end')));

    // Let any late uncaught-async-error report land inside this test's zone
    // so the leak fails the test instead of leaking past it.
    await Future<void>.delayed(const Duration(milliseconds: 20));

    started.manager.dispose();
  });
}
