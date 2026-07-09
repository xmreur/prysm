import 'package:prysm/models/chat/prysm_message.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/util/message_status_mapper.dart';

void main() {
  test('pending outbound row maps to clock state', () {
    final status = outboundStatusFromDbRow(
      row: {
        'senderId': 'me',
        'status': 'pending',
        'timestamp': 1000,
      },
      localUserId: 'me',
      readReceiptsEnabled: true,
    );
    expect(status.isPending, isTrue);
    expect(status.sentAt, isNull);
    expect(status.seenAt, isNull);
  });

  test('sent outbound row maps to single tick', () {
    final status = outboundStatusFromDbRow(
      row: {
        'senderId': 'me',
        'status': 'sent',
        'timestamp': 1000,
      },
      localUserId: 'me',
      readReceiptsEnabled: true,
    );
    expect(status.isDelivered, isTrue);
    expect(status.isRead, isFalse);
    expect(status.sentAt, isNotNull);
    expect(status.seenAt, isNull);
  });

  test('read receipts disabled hides read state', () {
    final status = outboundStatusFromDbRow(
      row: {
        'senderId': 'me',
        'status': 'sent',
        'timestamp': 1000,
      },
      localUserId: 'me',
      readReceiptsEnabled: false,
      receipts: [
        {'readerId': 'peer', 'readAt': 2000},
      ],
    );
    expect(status.isRead, isFalse);
    expect(status.seenAt, isNull);
  });

  test('direct read when peer receipt exists', () {
    final status = outboundStatusFromDbRow(
      row: {
        'senderId': 'me',
        'status': 'sent',
        'timestamp': 1000,
      },
      localUserId: 'me',
      readReceiptsEnabled: true,
      receipts: [
        {'readerId': 'peer', 'readAt': 2000},
      ],
      requiredReadCount: 1,
    );
    expect(status.isRead, isTrue);
    expect(status.seenAt?.millisecondsSinceEpoch, 2000);
  });

  test('group read requires all members', () {
    final partial = outboundStatusFromDbRow(
      row: {
        'senderId': 'me',
        'status': 'sent',
        'timestamp': 1000,
      },
      localUserId: 'me',
      readReceiptsEnabled: true,
      receipts: [
        {'readerId': 'a', 'readAt': 2000},
      ],
      requiredReadCount: 2,
    );
    expect(partial.isRead, isFalse);

    final allRead = outboundStatusFromDbRow(
      row: {
        'senderId': 'me',
        'status': 'sent',
        'timestamp': 1000,
      },
      localUserId: 'me',
      readReceiptsEnabled: true,
      receipts: [
        {'readerId': 'a', 'readAt': 2000},
        {'readerId': 'b', 'readAt': 2100},
      ],
      requiredReadCount: 2,
    );
    expect(allRead.isRead, isTrue);
  });

  test('messageWithDeliveryUpdate handles sent and pending', () {
    final msg = TextMessage(
      authorId: 'me',
      createdAt: DateTime.now(),
      id: '1',
      text: 'hi',
    );

    final pending = messageWithDeliveryUpdate(
      msg,
      status: 'pending',
      readReceiptsEnabled: true,
    );
    expect(pending.sentAt, isNull);
    expect(pending.metadata?['deliveryStatus'], 'pending');

    final sent = messageWithDeliveryUpdate(
      pending,
      status: 'sent',
      readReceiptsEnabled: true,
    );
    expect(sent.sentAt, isNotNull);
    expect(sent.seenAt, isNull);
  });

  test('outboundTickState maps pending, delivered, and read', () {
    final base = TextMessage(
      authorId: 'me',
      createdAt: DateTime.now(),
      id: '1',
      text: 'hi',
    );

    expect(
      outboundTickState(base, readReceiptsEnabled: true),
      OutboundTickState.pending,
    );

    final pending = messageWithPendingStatus(base);
    expect(
      outboundTickState(pending, readReceiptsEnabled: true),
      OutboundTickState.pending,
    );
    expect(pending.sentAt, isNull);

    final sent = messageWithDeliveryUpdate(
      pending,
      status: 'sent',
      readReceiptsEnabled: true,
    );
    expect(
      outboundTickState(sent, readReceiptsEnabled: true),
      OutboundTickState.delivered,
    );

    final read = messageWithDeliveryUpdate(
      sent,
      status: 'read',
      readReceiptsEnabled: true,
    );
    expect(
      outboundTickState(read, readReceiptsEnabled: true),
      OutboundTickState.read,
    );
    expect(
      outboundTickState(read, readReceiptsEnabled: false),
      OutboundTickState.delivered,
    );
  });
}
