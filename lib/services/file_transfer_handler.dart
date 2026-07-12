import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:prysm/crypto/envelope.dart';
import 'package:prysm/server/inbound_message_router.dart';
import 'package:prysm/server/PrysmServer.dart';
import 'package:prysm/services/block_service.dart';
import 'package:prysm/services/file_transfer_progress.dart';
import 'package:prysm/transport/transport_provider.dart';
import 'package:prysm/transport/ws_protocol.dart';
import 'package:prysm/util/file_transfer_policy.dart';
import 'package:prysm/util/logging.dart';

class _InboundTransfer {
  _InboundTransfer({
    required this.messageId,
    required this.senderId,
    required this.receiverId,
    required this.type,
    required this.fileName,
    required this.fileSize,
    required this.timestamp,
    required this.wrappedKey,
    required this.nonce,
    required this.ciphertextSize,
    required this.totalChunks,
    required this.chunkSize,
    this.replyTo,
    this.viewOnce = false,
  }) : buffer = Uint8List(ciphertextSize),
       receivedChunks = List<bool>.filled(totalChunks, false),
       lastActivity = DateTime.now();

  final String messageId;
  final String senderId;
  final String receiverId;
  final String type;
  final String fileName;
  final int fileSize;
  final int timestamp;
  final Map<String, dynamic> wrappedKey;
  final Uint8List nonce;
  final int ciphertextSize;
  final int totalChunks;
  final int chunkSize;
  final String? replyTo;
  final bool viewOnce;

  final Uint8List buffer;
  final List<bool> receivedChunks;
  DateTime lastActivity;

  int receivedCount = 0;

  double get progress =>
      totalChunks == 0 ? 0 : receivedCount / totalChunks;
}

/// Reassembles inbound chunked file transfers and delivers them as normal messages.
class FileTransferHandler {
  FileTransferHandler._();

  static final FileTransferHandler instance = FileTransferHandler._();

  final Map<String, _InboundTransfer> _active = {};
  Timer? _cleanupTimer;

  InboundMessageRouter? get _router =>
      _routerOverride ?? PrysmServer.instance?.inboundRouter;

  InboundMessageRouter? _routerOverride;

  @visibleForTesting
  set routerOverride(InboundMessageRouter? router) => _routerOverride = router;

  void start() {
    _cleanupTimer ??= Timer.periodic(
      const Duration(minutes: 1),
      (_) => _expireStaleTransfers(),
    );
  }

  void dispose() {
    _cleanupTimer?.cancel();
    _cleanupTimer = null;
    _active.clear();
    _routerOverride = null;
  }

  @visibleForTesting
  void resetForTest() {
    _cleanupTimer?.cancel();
    _cleanupTimer = null;
    _active.clear();
    _routerOverride = null;
  }

  Map<String, dynamic>? validateBegin(
    Map<String, dynamic> payload, {
    required String peerOnion,
    required String? localOnion,
  }) {
    if (localOnion == null || localOnion.isEmpty) {
      return {'error': 'Local onion unavailable'};
    }
    final senderId = payload['senderId'];
    final receiverId = payload['receiverId'];
    if (senderId is! String || senderId != peerOnion) {
      return {'error': 'Invalid sender'};
    }
    if (receiverId is! String || receiverId != localOnion) {
      return {'error': 'Invalid receiver'};
    }
    if (BlockService.instance.isBlocked(peerOnion)) {
      return {'error': 'Blocked'};
    }

    final requiredFields = [
      'transferId',
      'messageId',
      'type',
      'fileName',
      'fileSize',
      'timestamp',
      'wrappedKey',
      'nonce',
      'ciphertextSize',
      'totalChunks',
      'chunkSize',
    ];
    for (final field in requiredFields) {
      if (!payload.containsKey(field)) {
        return {'error': 'Missing $field'};
      }
    }

    final totalChunks = payload['totalChunks'];
    final chunkSize = payload['chunkSize'];
    final ciphertextSize = payload['ciphertextSize'];
    if (totalChunks is! int ||
        totalChunks <= 0 ||
        chunkSize is! int ||
        chunkSize <= 0 ||
        ciphertextSize is! int ||
        ciphertextSize <= 0) {
      return {'error': 'Invalid chunk metadata'};
    }
    if (totalChunks > 100_000) {
      return {'error': 'Too many chunks'};
    }

    final wrappedKey = payload['wrappedKey'];
    if (wrappedKey is! Map<String, dynamic>) {
      return {'error': 'Invalid wrappedKey'};
    }
    final nonceRaw = payload['nonce'];
    if (nonceRaw is! String) {
      return {'error': 'Invalid nonce'};
    }

    return null;
  }

  Future<Map<String, dynamic>> handleBegin(
    Map<String, dynamic> payload, {
    required String peerOnion,
    required String? localOnion,
  }) async {
    final error = validateBegin(
      payload,
      peerOnion: peerOnion,
      localOnion: localOnion,
    );
    if (error != null) {
      Logging.error('begin rejected from $peerOnion: $error', 'FileTransferHandler');
      return error;
    }

    final transferId = payload['transferId'] as String;
    final nonce = base64Decode(payload['nonce'] as String);

    _active[transferId] = _InboundTransfer(
      messageId: payload['messageId'] as String,
      senderId: payload['senderId'] as String,
      receiverId: payload['receiverId'] as String,
      type: payload['type'] as String,
      fileName: payload['fileName'] as String,
      fileSize: payload['fileSize'] as int,
      timestamp: payload['timestamp'] as int,
      wrappedKey: Map<String, dynamic>.from(
        payload['wrappedKey'] as Map<String, dynamic>,
      ),
      nonce: nonce,
      ciphertextSize: payload['ciphertextSize'] as int,
      totalChunks: payload['totalChunks'] as int,
      chunkSize: payload['chunkSize'] as int,
      replyTo: payload['replyTo'] as String?,
      viewOnce: payload['viewOnce'] == true,
    );

    FileTransferProgress.setDownload(
      payload['messageId'] as String,
      0,
    );

    Logging.debug(
      'begin accepted transfer=$transferId message=${payload['messageId']} '
      'from $peerOnion chunks=${payload['totalChunks']}',
      'FileTransferHandler',
    );

    return {'ok': true, 'transferId': transferId};
  }

  Future<void> handleChunk(
    FileTransferChunkFrame frame, {
    required String peerOnion,
    required Future<void> Function(String op, {Map<String, dynamic>? payload})
        sendAck,
  }) async {
    final session = _active[frame.transferId];
    if (session == null) {
      Logging.error(
        'chunk for unknown transfer ${frame.transferId} from $peerOnion',
        'FileTransferHandler',
      );
      return;
    }
    if (session.senderId != peerOnion) {
      Logging.error(
        'chunk sender mismatch ${session.senderId} vs $peerOnion',
        'FileTransferHandler',
      );
      return;
    }

    final index = frame.chunkIndex;
    if (index < 0 || index >= session.totalChunks) return;

    session.lastActivity = DateTime.now();
    final offset = index * session.chunkSize;
    if (offset >= session.buffer.length) return;

    final maxLen = session.buffer.length - offset;
    final len = frame.payload.length > maxLen ? maxLen : frame.payload.length;
    session.buffer.setRange(offset, offset + len, frame.payload.take(len));

    if (!session.receivedChunks[index]) {
      session.receivedChunks[index] = true;
      session.receivedCount++;
      FileTransferProgress.setDownload(session.messageId, session.progress);
    }

    await sendAck(
      'file_transfer_chunk_ack',
      payload: {
        'transferId': frame.transferId,
        'chunkIndex': index,
      },
    );
  }

  Future<Map<String, dynamic>> handleEnd(
    Map<String, dynamic> payload, {
    required String peerOnion,
  }) async {
    final transferId = payload['transferId'];
    if (transferId is! String) {
      return {'error': 'Missing transferId'};
    }

    final session = _active.remove(transferId);
    if (session == null) {
      return {'error': 'Unknown transfer'};
    }
    if (session.senderId != peerOnion) {
      return {'error': 'Invalid sender'};
    }
    if (session.receivedCount != session.totalChunks) {
      return {'error': 'Incomplete transfer'};
    }

    final envelope = CryptoEnvelope.fileAead1(
      wrappedKey: session.wrappedKey,
      nonce: session.nonce,
      ciphertext: session.buffer,
    );
    final wire = CryptoEnvelope.encode(envelope);

    final router = _router;
    if (router == null) {
      return {'error': 'Router unavailable'};
    }

    final messagePayload = <String, dynamic>{
      'id': session.messageId,
      'senderId': session.senderId,
      'receiverId': session.receiverId,
      'message': wire,
      'type': session.type,
      'fileName': session.fileName,
      'fileSize': session.fileSize,
      'timestamp': session.timestamp,
      if (session.replyTo != null) 'replyTo': session.replyTo,
      'viewOnce': session.viewOnce,
    };

    try {
      final result = await router.processMessage(messagePayload);
      FileTransferProgress.setDownload(session.messageId, 1.0);
      if (result.statusCode >= 400) {
        return {
          'error': result.jsonBody?['error']?.toString() ?? 'Processing failed',
        };
      }
      return {'ok': true, 'messageId': session.messageId};
    } catch (e, stack) {
      Logging.error('file transfer end failed: $e\n$stack', 'FileTransferHandler');
      return {'error': 'Processing failed'};
    }
  }

  Future<void> handleBinaryChunk(
    List<int> raw, {
    required String peerOnion,
    Future<void> Function(String op, {Map<String, dynamic>? payload})? sendAck,
  }) async {
    FileTransferChunkFrame frame;
    try {
      frame = FileTransferChunkFrame.decode(raw);
    } catch (e) {
      Logging.error('invalid chunk frame from $peerOnion: $e', 'FileTransferHandler');
      return;
    }

    Future<void> ack(String op, {Map<String, dynamic>? payload}) async {
      if (sendAck != null) {
        await sendAck(op, payload: payload);
        return;
      }
      if (!TransportProvider.isConfigured) return;
      await TransportProvider.instance.wsManager.send(
        peerOnion,
        op,
        payload: payload,
      );
    }

    await handleChunk(frame, peerOnion: peerOnion, sendAck: ack);
  }

  void _expireStaleTransfers() {
    final now = DateTime.now();
    final expired = <String>[];
    for (final entry in _active.entries) {
      if (now.difference(entry.value.lastActivity) > FileTransferPolicy.transferTtl) {
        expired.add(entry.key);
        FileTransferProgress.clearDownload(entry.value.messageId);
      }
    }
    for (final id in expired) {
      _active.remove(id);
    }
  }
}
