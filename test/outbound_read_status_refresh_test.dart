import 'package:prysm/models/chat/prysm_message.dart';
import 'package:prysm/ui/chat/prysm_chat_message_list.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/util/outbound_read_status_refresh.dart';

TextMessage _outbound({
  required String id,
  int timestamp = 1000,
  DateTime? sentAt,
}) {
  return TextMessage(
    authorId: 'me',
    createdAt: DateTime.fromMillisecondsSinceEpoch(timestamp),
    id: id,
    text: 'hi',
    sentAt: sentAt ?? DateTime.fromMillisecondsSinceEpoch(timestamp),
    metadata: const {'deliveryStatus': 'sent'},
  );
}

void main() {
  group('applyReadStatusFromReceipts', () {
    test('waterline: all three outbound messages marked read', () {
      final messages = [
        _outbound(id: 'msg-1', timestamp: 100),
        _outbound(id: 'msg-2', timestamp: 200),
        _outbound(id: 'msg-3', timestamp: 300),
      ];

      final refreshed = applyReadStatusFromReceipts(
        messages: messages,
        localUserId: 'me',
        readReceiptsEnabled: true,
        receiptsByWireId: {
          'msg-1': [
            {'readerId': 'peer', 'readAt': 500},
          ],
          'msg-2': [
            {'readerId': 'peer', 'readAt': 500},
          ],
          'msg-3': [
            {'readerId': 'peer', 'readAt': 500},
          ],
        },
      );

      for (final msg in refreshed) {
        expect(msg.seenAt, isNotNull);
        expect(msg.metadata?['deliveryStatus'], 'read');
      }
    });

    test('direct chat: only messaged with receipt marked read', () {
      final messages = [
        _outbound(id: 'msg-1', timestamp: 100),
        _outbound(id: 'msg-2', timestamp: 200),
      ];

      final refreshed = applyReadStatusFromReceipts(
        messages: messages,
        localUserId: 'me',
        readReceiptsEnabled: true,
        receiptsByWireId: {
          'msg-2': [
            {'readerId': 'peer', 'readAt': 500},
          ],
        },
      );

      expect(refreshed[0].seenAt, isNull);
      expect(refreshed[1].seenAt, isNotNull);
    });

    test('group: partial reads do not mark fully read', () {
      final messages = [_outbound(id: 'msg-1')];

      final oneReader = applyReadStatusFromReceipts(
        messages: messages,
        localUserId: 'me',
        readReceiptsEnabled: true,
        receiptsByWireId: {
          'msg-1': [
            {'readerId': 'a', 'readAt': 500},
          ],
        },
        requiredReadCount: 2,
      );
      expect(oneReader.single.seenAt, isNull);

      final twoReaders = applyReadStatusFromReceipts(
        messages: messages,
        localUserId: 'me',
        readReceiptsEnabled: true,
        receiptsByWireId: {
          'msg-1': [
            {'readerId': 'a', 'readAt': 500},
            {'readerId': 'b', 'readAt': 600},
          ],
        },
        requiredReadCount: 2,
      );
      expect(twoReaders.single.seenAt, isNotNull);
      expect(
        twoReaders.single.seenAt!.millisecondsSinceEpoch,
        600,
      );
    });

    test('inbound messages are unchanged', () {
      final messages = [
        TextMessage(
          authorId: 'peer',
          createdAt: DateTime.fromMillisecondsSinceEpoch(100),
          id: 'in-1',
          text: 'hello',
        ),
        _outbound(id: 'msg-1'),
      ];

      final refreshed = applyReadStatusFromReceipts(
        messages: messages,
        localUserId: 'me',
        readReceiptsEnabled: true,
        receiptsByWireId: {
          'msg-1': [
            {'readerId': 'peer', 'readAt': 500},
          ],
        },
      );

      expect(refreshed[0].seenAt, isNull);
      expect(refreshed[1].seenAt, isNotNull);
    });
  });
}
