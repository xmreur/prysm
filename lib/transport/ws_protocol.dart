import 'dart:convert';
import 'dart:typed_data';

import 'package:prysm/constants/group_constants.dart';

const int wsProtocolVersion = 1;

const List<String> wsSupportedOps = [
  'message',
  'read_update',
  'reaction_update',
  'message_modify',
  'typing_update',
  'sync-hint',
  'profile',
  'public',
  'call_offer',
  'call_answer',
  'call_end',
  'call_mute',
  'file_transfer',
];

const String wsFileTransferCapability = 'file_transfer';

const List<String> wsFileTransferOps = [
  'file_transfer_begin',
  'file_transfer_end',
  'file_transfer_begin_ack',
  'file_transfer_end_ack',
  'file_transfer_chunk_ack',
];

const List<String> wsCallOps = [
  'call_offer',
  'call_answer',
  'call_end',
  'call_mute',
];

const int callAudioFrameMagic = 0xA1;
const int callAudioFrameHeaderLength = 9;

const int fileTransferChunkMagic = 0xA2;
const int fileTransferChunkHeaderLength = 21; // magic + 16-byte UUID + index

/// Maps an inbound message [type] to the WebSocket command sent on the wire.
String wsOpForPayloadType(String type) {
  if (isReadReceiptType(type)) return 'read_update';
  if (isReactionType(type)) return 'reaction_update';
  if (isMessageModifyType(type)) return 'message_modify';
  if (type == 'sync-hint') return 'sync-hint';
  return 'message';
}

class WsFrame {
  final int version;
  final String op;
  final String? id;
  final Map<String, dynamic>? payload;

  const WsFrame({
    this.version = wsProtocolVersion,
    required this.op,
    this.id,
    this.payload,
  });

  Map<String, dynamic> toJson() => {
        'v': version,
        'op': op,
        if (id != null) 'id': id,
        if (payload != null) 'payload': payload,
      };

  String encode() => jsonEncode(toJson());

  static WsFrame decode(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('WS frame must be a JSON object');
    }
    final op = decoded['op'];
    if (op is! String || op.isEmpty) {
      throw const FormatException('WS frame missing op');
    }
    final version = decoded['v'];
    final id = decoded['id'];
    final payload = decoded['payload'];
    return WsFrame(
      version: version is int ? version : wsProtocolVersion,
      op: op,
      id: id is String ? id : null,
      payload: payload is Map<String, dynamic> ? payload : null,
    );
  }

  static WsFrame hello({
    List<String>? supports,
    String? onion,
  }) =>
      WsFrame(
        op: 'hello',
        payload: {
          'supports': supports ?? wsSupportedOps,
          if (onion != null && onion.isNotEmpty) 'onion': onion,
        },
      );

  static WsFrame ping() => const WsFrame(op: 'ping');

  static WsFrame pong() => const WsFrame(op: 'pong');

  static WsFrame response({
    required String op,
    required String id,
    Map<String, dynamic>? payload,
  }) =>
      WsFrame(op: op, id: id, payload: payload);

  static WsFrame error({required String id, required String message}) =>
      WsFrame(op: 'error', id: id, payload: {'error': message});

  /// Side-channel ops carry the same JSON body as HTTP POST /message.
  static bool isInboundSideChannelOp(String op) =>
      op == 'read_update' ||
      op == 'reaction_update' ||
      op == 'message_modify';

  static bool isTypingOp(String op) => op == 'typing_update';

  static bool routesToMessageHandler(String op) =>
      op == 'message' || isInboundSideChannelOp(op);

  static bool isCallOp(String op) => wsCallOps.contains(op);

  static bool isFileTransferOp(String op) => wsFileTransferOps.contains(op);

  static bool isFileTransferRequestOp(String op) =>
      op == 'file_transfer_begin' || op == 'file_transfer_end';
}

/// Binary wire format for encrypted Opus audio during an active call.
class CallAudioFrame {
  const CallAudioFrame({
    required this.sessionId,
    required this.seq,
    required this.payload,
  });

  final int sessionId;
  final int seq;
  final List<int> payload;

  Uint8List encode() {
    final out = Uint8List(callAudioFrameHeaderLength + payload.length);
    out[0] = callAudioFrameMagic;
    final view = ByteData.sublistView(out);
    view.setUint32(1, sessionId, Endian.big);
    view.setUint32(5, seq, Endian.big);
    out.setRange(callAudioFrameHeaderLength, out.length, payload);
    return out;
  }

  static CallAudioFrame decode(List<int> raw) {
    if (raw.length < callAudioFrameHeaderLength) {
      throw const FormatException('Call audio frame too short');
    }
    if (raw[0] != callAudioFrameMagic) {
      throw const FormatException('Invalid call audio frame magic');
    }
    final view = ByteData.sublistView(Uint8List.fromList(raw));
    final sessionId = view.getUint32(1, Endian.big);
    final seq = view.getUint32(5, Endian.big);
    final payload = raw.sublist(callAudioFrameHeaderLength);
    return CallAudioFrame(
      sessionId: sessionId,
      seq: seq,
      payload: payload,
    );
  }
}

/// Binary wire format for encrypted file ciphertext chunks.
class FileTransferChunkFrame {
  const FileTransferChunkFrame({
    required this.transferId,
    required this.chunkIndex,
    required this.payload,
  });

  final String transferId;
  final int chunkIndex;
  final List<int> payload;

  Uint8List encode() {
    final transferBytes = transferIdToBytes(transferId);
    final out = Uint8List(fileTransferChunkHeaderLength + payload.length);
    out[0] = fileTransferChunkMagic;
    out.setRange(1, 17, transferBytes);
    final view = ByteData.sublistView(out);
    view.setUint32(17, chunkIndex, Endian.big);
    out.setRange(fileTransferChunkHeaderLength, out.length, payload);
    return out;
  }

  static FileTransferChunkFrame decode(List<int> raw) {
    if (raw.length < fileTransferChunkHeaderLength) {
      throw const FormatException('File transfer chunk frame too short');
    }
    if (raw[0] != fileTransferChunkMagic) {
      throw const FormatException('Invalid file transfer chunk magic');
    }
    final transferId = transferIdFromBytes(Uint8List.fromList(raw.sublist(1, 17)));
    final view = ByteData.sublistView(Uint8List.fromList(raw));
    final chunkIndex = view.getUint32(17, Endian.big);
    final payload = raw.sublist(fileTransferChunkHeaderLength);
    return FileTransferChunkFrame(
      transferId: transferId,
      chunkIndex: chunkIndex,
      payload: payload,
    );
  }
}

Uint8List transferIdToBytes(String transferId) {
  final normalized = transferId.replaceAll('-', '');
  if (normalized.length != 32) {
    throw FormatException('Invalid transfer id: $transferId');
  }
  final out = Uint8List(16);
  for (var i = 0; i < 16; i++) {
    out[i] = int.parse(normalized.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String transferIdFromBytes(Uint8List bytes) {
  if (bytes.length != 16) {
    throw const FormatException('Transfer id bytes must be 16 bytes');
  }
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-'
      '${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-'
      '${hex.substring(16, 20)}-'
      '${hex.substring(20)}';
}
