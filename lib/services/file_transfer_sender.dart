import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:prysm/crypto/constants.dart';
import 'package:prysm/crypto/envelope.dart';
import 'package:prysm/services/file_transfer_progress.dart';
import 'package:prysm/services/ws_connection_manager.dart';
import 'package:prysm/transport/ws_protocol.dart';
import 'package:prysm/util/file_transfer_policy.dart';
import 'package:prysm/util/logging.dart';
import 'package:uuid/uuid.dart';

class FileTransferParts {
  const FileTransferParts({
    required this.wrappedKey,
    required this.nonce,
    required this.ciphertext,
  });

  final Map<String, dynamic> wrappedKey;
  final Uint8List nonce;
  final Uint8List ciphertext;
}

FileTransferParts parseFileTransferParts(String peerPayload) {
  final envelope = CryptoEnvelope.tryParse(peerPayload);
  if (envelope == null ||
      envelope['scheme'] != CryptoConstants.schemeFileAead1) {
    throw const FormatException('Invalid file envelope');
  }
  final wrappedKey = envelope['wrappedKey'];
  if (wrappedKey is! Map<String, dynamic>) {
    throw const FormatException('Invalid wrappedKey');
  }
  return FileTransferParts(
    wrappedKey: Map<String, dynamic>.from(wrappedKey),
    nonce: base64Decode(envelope['nonce'] as String),
    ciphertext: base64Decode(envelope['ciphertext'] as String),
  );
}

/// Sends encrypted file ciphertext in WebSocket chunks with per-chunk acks.
class FileTransferSender {
  FileTransferSender(this._manager);

  final WsConnectionManager _manager;

  Future<bool> send({
    required String peerOnion,
    required String messageId,
    required String senderId,
    required String receiverId,
    required String type,
    required String fileName,
    required int fileSize,
    required String peerPayload,
    String? replyToId,
    bool viewOnce = false,
    Duration timeout = const Duration(minutes: 5),
  }) async {
    final parts = parseFileTransferParts(peerPayload);
    final ciphertext = parts.ciphertext;
    final chunkSize = FileTransferPolicy.chunkSizeBytes;
    final totalChunks = FileTransferPolicy.chunkCountForSize(ciphertext.length);
    if (totalChunks == 0) return false;

    final transferId = const Uuid().v4();
    final progress = FileTransferProgress.uploadNotifier(messageId);
    progress.value = 0;

    StreamSubscription<Map<String, dynamic>>? controlSub;
    final pendingChunkAcks = <String, Completer<void>>{};

    void completeChunkAck(String key) {
      pendingChunkAcks.remove(key)?.complete();
    }

    controlSub = _manager.pushFramesFor(peerOnion).listen((frame) {
      final op = frame['op'];
      if (!WsFrame.isFileTransferOp(op is String ? op : '')) return;

      final payload = frame['payload'];
      if (payload is! Map<String, dynamic>) {
        Logging.debug(
          'ignoring file-transfer frame op=$op without map payload',
          'FileTransferSender',
        );
        return;
      }

      if (op == 'file_transfer_chunk_ack') {
        final tid = payload['transferId'];
        final index = payload['chunkIndex'];
        if (tid is! String || index is! int) {
          Logging.debug(
            'ignoring chunk_ack with bad fields tid=$tid index=$index',
            'FileTransferSender',
          );
          return;
        }
        if (tid != transferId) return;
        Logging.debug(
          'chunk_ack ${index + 1}/$totalChunks transfer=$transferId',
          'FileTransferSender',
        );
        completeChunkAck('$tid:$index');
      } else if (op == 'file_transfer_begin_ack' || op == 'file_transfer_end_ack') {
        Logging.debug(
          'push $op transfer=${payload['transferId']} payload=$payload',
          'FileTransferSender',
        );
      }
    });

    try {
      if (!_manager.isConnected(peerOnion)) {
        await _manager.prepareForFileTransfer(peerOnion);
      } else {
        _manager.pinPeer(peerOnion);
      }
      Logging.debug('WS ready peer=$peerOnion', 'FileTransferSender');

      Logging.debug(
        'begin transfer=$transferId message=$messageId chunks=$totalChunks '
        'ciphertext=${ciphertext.length} peer=$peerOnion',
        'FileTransferSender',
      );

      final beginResult = await _manager.request(
        peerOnion,
        'file_transfer_begin',
        payload: {
          'transferId': transferId,
          'messageId': messageId,
          'senderId': senderId,
          'receiverId': receiverId,
          'type': type,
          'fileName': fileName,
          'fileSize': fileSize,
          'timestamp': DateTime.now().millisecondsSinceEpoch,
          'wrappedKey': parts.wrappedKey,
          'nonce': base64Encode(parts.nonce),
          'ciphertextSize': ciphertext.length,
          'totalChunks': totalChunks,
          'chunkSize': chunkSize,
          if (replyToId != null) 'replyTo': replyToId,
          'viewOnce': viewOnce,
        },
        bypassQueue: true,
        timeout: const Duration(seconds: 30),
      );

      if (beginResult.containsKey('error')) {
        throw StateError(
          beginResult['error']?.toString() ?? 'begin rejected',
        );
      }

      Logging.debug(
        'begin ack transfer=$transferId result=$beginResult',
        'FileTransferSender',
      );

      var ackedChunks = 0;
      for (var index = 0; index < totalChunks; index++) {
        final offset = index * chunkSize;
        final end = offset + chunkSize > ciphertext.length
            ? ciphertext.length
            : offset + chunkSize;
        final chunkBytes = ciphertext.sublist(offset, end);
        final frame = FileTransferChunkFrame(
          transferId: transferId,
          chunkIndex: index,
          payload: chunkBytes,
        );

        var sent = false;
        for (var attempt = 0;
            attempt < FileTransferPolicy.maxChunkRetries;
            attempt++) {
          final ackKey = '$transferId:$index';
          final ackCompleter = Completer<void>();
          pendingChunkAcks[ackKey] = ackCompleter;

          await _manager.sendBytes(peerOnion, frame.encode());
          Logging.debug(
            'chunk ${index + 1}/$totalChunks sent bytes=${chunkBytes.length} '
            'transfer=$transferId',
            'FileTransferSender',
          );

          try {
            await ackCompleter.future.timeout(const Duration(seconds: 60));
            sent = true;
            break;
          } on TimeoutException {
            pendingChunkAcks.remove(ackKey);
            Logging.debug(
              'chunk $index/$totalChunks ack timeout attempt=${attempt + 1} '
              'transfer=$transferId',
              'FileTransferSender',
            );
          }
        }

        if (!sent) {
          Logging.error(
            'chunk $index/$totalChunks ack timeout transfer=$transferId',
            'FileTransferSender',
          );
          return false;
        }

        ackedChunks++;
        progress.value = ackedChunks / totalChunks;
      }

      final endResult = await _manager.request(
        peerOnion,
        'file_transfer_end',
        payload: {'transferId': transferId},
        bypassQueue: true,
        timeout: const Duration(seconds: 30),
      );

      if (endResult.containsKey('error')) {
        throw StateError(endResult['error']?.toString() ?? 'end rejected');
      }

      Logging.debug(
        'end ack transfer=$transferId result=$endResult',
        'FileTransferSender',
      );

      progress.value = 1.0;
      Logging.debug('transfer complete message=$messageId', 'FileTransferSender');
      return true;
    } catch (e, stack) {
      Logging.error('file transfer failed: $e\n$stack', 'FileTransferSender');
      return false;
    } finally {
      await controlSub.cancel();
      for (final completer in pendingChunkAcks.values) {
        if (!completer.isCompleted) {
          completer.completeError(StateError('transfer cancelled'));
        }
      }
      pendingChunkAcks.clear();
    }
  }
}
