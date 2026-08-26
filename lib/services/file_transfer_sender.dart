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
    required this.scheme,
    required this.wrappedKey,
    required this.nonce,
    required this.ciphertext,
  });

  final String scheme;
  final Map<String, dynamic> wrappedKey;
  final Uint8List nonce;
  final Uint8List ciphertext;
}

FileTransferParts parseFileTransferParts(String peerPayload) {
  final envelope = CryptoEnvelope.tryParse(peerPayload);
  final scheme = envelope?['scheme'];
  if (envelope == null ||
      (scheme != CryptoConstants.schemeFileAead1 &&
          scheme != CryptoConstants.schemeFileSigned1)) {
    throw const FormatException('Invalid file envelope');
  }
  final wrappedKey = envelope['wrappedKey'];
  if (wrappedKey is! Map<String, dynamic>) {
    throw const FormatException('Invalid wrappedKey');
  }
  return FileTransferParts(
    scheme: scheme as String,
    wrappedKey: Map<String, dynamic>.from(wrappedKey),
    nonce: base64Decode(envelope['nonce'] as String),
    ciphertext: base64Decode(envelope['ciphertext'] as String),
  );
}

/// Sends encrypted file ciphertext in WebSocket chunks with per-chunk acks.
class FileTransferSender {
  FileTransferSender(
    this._manager, {
    this.ackTimeout = const Duration(seconds: 60),
    this.beginAckTimeout = FileTransferPolicy.beginAckTimeout,
  });

  final WsConnectionManager _manager;

  /// Per-chunk ack wait before a retry. Injectable so tests can drive the
  /// retry/abort paths without a real 60 s delay; production keeps 60 s.
  final Duration ackTimeout;

  /// Wait for the begin ack on an allegedly-ready link before rebuilding it.
  /// Injectable so tests can drive the stale-link path without the real 2 s.
  final Duration beginAckTimeout;

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
    bool forwarded = false,
    int? expiresAt,
    int? timestamp,
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

    // Set once send() unwinds: a retry loop that was between attempts (its
    // ack key already dropped) must not re-register a completer and resend
    // frames after controlSub is cancelled. Local to send(), never a field:
    // a field would leak one send's abandonment into a concurrent one.
    var abandoned = false;

    void completeChunkAck(String key) {
      pendingChunkAcks.remove(key)?.complete();
    }

    try {
      // The begin ack is the proof that the receiver actually accepted the
      // link: a timeout on an allegedly-ready link means the link is stale,
      // so tear it down and re-dial before giving up to the HTTP fallback.
      // Begin/end acks are request responses, so the push subscription only
      // needs to be live for chunk acks and is attached after begin succeeds.
      final wireTimestamp = timestamp ?? DateTime.now().millisecondsSinceEpoch;
      for (var attempt = 0; ; attempt++) {
        if (attempt > 0) {
          Logging.debug(
            'begin not acked, rebuilding link peer=$peerOnion',
            'FileTransferSender',
          );
          await _manager
              .disconnectPeer(peerOnion)
              .then((_) => _manager.prepareForFileTransfer(peerOnion))
              .timeout(beginAckTimeout);
        } else {
          await _manager.prepareForFileTransfer(peerOnion);
        }
        Logging.debug('WS ready peer=$peerOnion', 'FileTransferSender');

        Logging.debug(
          'begin transfer=$transferId message=$messageId chunks=$totalChunks '
          'ciphertext=${ciphertext.length} peer=$peerOnion',
          'FileTransferSender',
        );

        final Map<String, dynamic> beginResult;
        try {
          beginResult = await _manager.request(
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
              'timestamp': wireTimestamp,
              'wrappedKey': parts.wrappedKey,
              'nonce': base64Encode(parts.nonce),
              'scheme': parts.scheme,
              'ciphertextSize': ciphertext.length,
              'totalChunks': totalChunks,
              'chunkSize': chunkSize,
              'replyTo': ?replyToId,
              'viewOnce': viewOnce,
              if (forwarded) 'forwarded': true,
              'expiresAt': ?expiresAt,
            },
            bypassQueue: true,
            timeout: beginAckTimeout,
          );
        } on TimeoutException {
          if (attempt >= FileTransferPolicy.beginRetries) rethrow;
          continue;
        }

        if (beginResult.containsKey('error')) {
          throw StateError(
            beginResult['error']?.toString() ?? 'begin rejected',
          );
        }

        Logging.debug(
          'begin ack transfer=$transferId result=$beginResult',
          'FileTransferSender',
        );
        break;
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
        } else if (op == 'file_transfer_begin_ack' ||
            op == 'file_transfer_end_ack') {
          Logging.debug(
            'push $op transfer=${payload['transferId']} payload=$payload',
            'FileTransferSender',
          );
        }
      });

      var ackedChunks = 0;
      var nextIndex = 0;
      var inFlight = 0;
      final allChunksAcked = Completer<void>();
      final transferFailed = Completer<void>();
      Completer<void>? refill;

      void kickRefill() {
        final pending = refill;
        refill = null;
        if (pending != null && !pending.isCompleted) {
          pending.complete();
        }
      }

      // Sends one chunk (with per-index retries) and waits for its ack. The
      // frame is built lazily at send time so the window never holds W × 256
      // KiB of pre-sliced copies; only the sink buffers the in-flight frames.
      Future<void> sendChunkWithRetries(int index) async {
        try {
          var sent = false;
          for (var attempt = 0;
              attempt < FileTransferPolicy.maxChunkRetries;
              attempt++) {
            // send() may have finished while this chunk sat between
            // attempts: its old ack key is already gone, so continuing
            // would strand a fresh completer and send frames on a
            // subscription that will never ack them.
            if (abandoned || transferFailed.isCompleted) return;
            final ackKey = '$transferId:$index';
            final ackCompleter = Completer<void>();
            pendingChunkAcks[ackKey] = ackCompleter;

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

            // The completer must be registered before sendBytes so an ack
            // racing ahead of the send future can still complete it; if the
            // send itself fails no ack will ever arrive, so drop the entry
            // here rather than leave it for send()'s finally to completeError
            // on a future nobody listens to (an uncaught async error).
            try {
              await _manager.sendBytes(peerOnion, frame.encode());
            } catch (_) {
              pendingChunkAcks.remove(ackKey);
              rethrow;
            }
            Logging.debug(
              'chunk ${index + 1}/$totalChunks sent bytes=${chunkBytes.length} '
              'transfer=$transferId',
              'FileTransferSender',
            );

            try {
              await ackCompleter.future.timeout(ackTimeout);
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
            if (!transferFailed.isCompleted) transferFailed.complete();
            return;
          }

          ackedChunks++;
          progress.value = ackedChunks / totalChunks;
          if (ackedChunks == totalChunks && !allChunksAcked.isCompleted) {
            allChunksAcked.complete();
          }
        } catch (e, stack) {
          if (!transferFailed.isCompleted) {
            transferFailed.completeError(e, stack);
          }
        } finally {
          inFlight--;
          kickRefill();
        }
      }

      // Keeps at most chunkWindowSize chunks in flight; refills the window as
      // acks drain it. All indices must be acked (not just an in-order
      // prefix) before the transfer is allowed to finish.
      Future<void> pumpWindow() async {
        while (nextIndex < totalChunks &&
            !transferFailed.isCompleted &&
            !allChunksAcked.isCompleted) {
          while (nextIndex < totalChunks &&
              inFlight < FileTransferPolicy.chunkWindowSize) {
            final index = nextIndex++;
            inFlight++;
            unawaited(sendChunkWithRetries(index));
          }
          if (nextIndex >= totalChunks) break;
          refill = Completer<void>();
          await refill!.future;
        }
      }

      unawaited(pumpWindow());
      await Future.any([allChunksAcked.future, transferFailed.future]);
      if (transferFailed.isCompleted) return false;

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
      // Stop any chunk still looping through retries from sending more
      // frames once the ack subscription is gone.
      abandoned = true;
      await controlSub?.cancel();
      for (final completer in pendingChunkAcks.values) {
        if (!completer.isCompleted) {
          completer.completeError(StateError('transfer cancelled'));
        }
      }
      pendingChunkAcks.clear();
    }
  }
}
