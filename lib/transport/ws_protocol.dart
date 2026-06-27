import 'dart:convert';

import 'package:prysm/constants/group_constants.dart';

const int wsProtocolVersion = 1;

const List<String> wsSupportedOps = [
  'message',
  'read_update',
  'reaction_update',
  'message_modify',
  'sync-hint',
  'profile',
  'public',
];

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

  static bool routesToMessageHandler(String op) =>
      op == 'message' || isInboundSideChannelOp(op);
}
