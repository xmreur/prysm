import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/constants/group_constants.dart';
import 'package:prysm/util/read_receipt_payload.dart';
import 'package:prysm/util/read_waterline_mark.dart';

void main() {
  group('ReadReceiptPayload waterline', () {
    test('encodes and decodes readUpToTimestamp', () {
      const payload = ReadReceiptPayload(
        targetMessageId: 'msg-latest',
        readerId: 'reader.onion',
        timestamp: 1_717_890_000_000,
        readUpToTimestamp: 1_717_889_000_000,
      );

      expect(payload.isWaterline, isTrue);
      expect(payload.effectiveReadUpToTimestamp, 1_717_889_000_000);

      final decoded = ReadReceiptPayload.decode(payload.encode());
      expect(decoded.targetMessageId, 'msg-latest');
      expect(decoded.readUpToTimestamp, 1_717_889_000_000);
      expect(decoded.isWaterline, isTrue);
    });

    test('legacy receipt without waterline uses timestamp', () {
      const payload = ReadReceiptPayload(
        targetMessageId: 'msg-1',
        readerId: 'reader.onion',
        timestamp: 500,
      );

      expect(payload.isWaterline, isFalse);
      expect(payload.effectiveReadUpToTimestamp, 500);
    });

    test('decodes latestMessageId alias', () {
      final decoded = ReadReceiptPayload.fromJson({
        'latestMessageId': 'wire-id',
        'readerId': 'r',
        'timestamp': 1,
        'readUpToTimestamp': 1,
      });
      expect(decoded.targetMessageId, 'wire-id');
    });
  });

  group('readWaterlineEventId', () {
    test('direct conversation key is stable per peer', () {
      expect(
        readWaterlineEventId(readerId: 'me', peerId: 'peer.onion'),
        'read_waterline::me::peer.onion',
      );
    });

    test('group key includes group id', () {
      expect(
        readWaterlineEventId(
          readerId: 'me',
          peerId: 'me',
          groupId: 'group-1',
        ),
        'read_waterline::me::group-1',
      );
    });
  });

  group('ReadWaterlineMark', () {
    test('carries group id when set', () {
      const mark = ReadWaterlineMark(
        latestMessageId: 'm1',
        readUpToTimestamp: 100,
        groupId: 'g1',
      );
      expect(mark.groupId, 'g1');
    });
  });
}
