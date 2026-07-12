import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/constants/group_constants.dart';
import 'package:prysm/transport/ws_protocol.dart';

void main() {
  group('WsFrame', () {
    test('encodes and decodes message frame', () {
      const frame = WsFrame(
        op: 'message',
        payload: {'id': 'abc', 'type': 'text'},
      );
      final decoded = WsFrame.decode(frame.encode());
      expect(decoded.op, 'message');
      expect(decoded.payload, {'id': 'abc', 'type': 'text'});
    });

    test('hello frame includes supported ops', () {
      final frame = WsFrame.hello(onion: 'me.onion');
      expect(frame.op, 'hello');
      expect(frame.payload?['supports'], wsSupportedOps);
      expect(frame.payload?['onion'], 'me.onion');
    });

    test('wsOpForPayloadType maps side channels to command ops', () {
      expect(wsOpForPayloadType(readWaterlineType), 'read_update');
      expect(wsOpForPayloadType(reactionType), 'reaction_update');
      expect(wsOpForPayloadType(messageModifyType), 'message_modify');
      expect(wsOpForPayloadType('text'), 'message');
    });

    test('typing_update is a supported op and typing side channel', () {
      expect(wsSupportedOps, contains('typing_update'));
      expect(WsFrame.isTypingOp('typing_update'), isTrue);
      expect(WsFrame.isTypingOp('message'), isFalse);
    });

    test('response frame preserves correlation id', () {
      final frame = WsFrame.response(
        op: 'profile',
        id: 'req-1',
        payload: {'username': 'alice'},
      );
      final decoded = WsFrame.decode(frame.encode());
      expect(decoded.id, 'req-1');
      expect(decoded.op, 'profile');
    });

    test('call ops are supported and detected', () {
      expect(wsSupportedOps, contains('call_offer'));
      expect(WsFrame.isCallOp('call_answer'), isTrue);
      expect(WsFrame.isCallOp('message'), isFalse);
    });

    test('file transfer ops are supported and detected', () {
      expect(wsSupportedOps, contains(wsFileTransferCapability));
      expect(WsFrame.isFileTransferOp('file_transfer_begin'), isTrue);
      expect(WsFrame.isFileTransferRequestOp('file_transfer_end'), isTrue);
      expect(WsFrame.isFileTransferRequestOp('file_transfer_chunk_ack'), isFalse);
    });
  });

  group('FileTransferChunkFrame', () {
    test('round-trips binary payload', () {
      const transferId = '550e8400-e29b-41d4-a716-446655440000';
      const frame = FileTransferChunkFrame(
        transferId: transferId,
        chunkIndex: 3,
        payload: [9, 8, 7],
      );
      final decoded = FileTransferChunkFrame.decode(frame.encode());
      expect(decoded.transferId, transferId);
      expect(decoded.chunkIndex, 3);
      expect(decoded.payload, [9, 8, 7]);
    });

    test('rejects invalid magic', () {
      expect(
        () => FileTransferChunkFrame.decode([0x00, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        throwsFormatException,
      );
    });
  });

  group('CallAudioFrame', () {
    test('round-trips binary payload', () {
      const frame = CallAudioFrame(
        sessionId: 42,
        seq: 7,
        payload: [1, 2, 3],
      );
      final decoded = CallAudioFrame.decode(frame.encode());
      expect(decoded.sessionId, 42);
      expect(decoded.seq, 7);
      expect(decoded.payload, [1, 2, 3]);
    });

    test('rejects invalid magic', () {
      expect(
        () => CallAudioFrame.decode([0x00, 0, 0, 0, 0, 0, 0, 0, 0]),
        throwsFormatException,
      );
    });
  });
}
