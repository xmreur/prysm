import 'package:prysm/models/chat/prysm_message.dart';

/// Delivery/read state for outgoing message ticks.
class OutboundMessageStatus {
  final bool isPending;
  final bool isFailed;
  final bool isDelivered;
  final bool isRead;
  final DateTime? sentAt;
  final DateTime? seenAt;

  const OutboundMessageStatus({
    this.isPending = false,
    this.isFailed = false,
    this.isDelivered = false,
    this.isRead = false,
    this.sentAt,
    this.seenAt,
  });
}

OutboundMessageStatus outboundStatusFromDbRow({
  required Map<String, dynamic> row,
  required String localUserId,
  required bool readReceiptsEnabled,
  List<Map<String, dynamic>> receipts = const [],
  int requiredReadCount = 1,
}) {
  final senderId = row['senderId'] as String;
  if (senderId != localUserId) {
    return const OutboundMessageStatus();
  }

  final status = (row['status'] as String?) ?? 'sent';
  final timestamp = row['timestamp'] as int?;
  final sentAt = timestamp != null
      ? DateTime.fromMillisecondsSinceEpoch(timestamp)
      : null;

  if (status == 'pending') {
    return OutboundMessageStatus(isPending: true);
  }

  final receiptCount = receipts.length;
  final allRead = receiptCount >= requiredReadCount && requiredReadCount > 0;
  final isRead = readReceiptsEnabled && allRead;
  final latestReadAt = receipts.isEmpty
      ? null
      : receipts
          .map((r) => r['readAt'] as int)
          .reduce((a, b) => a > b ? a : b);

  return OutboundMessageStatus(
    isDelivered: status == 'sent',
    isRead: isRead,
    sentAt: status == 'sent' ? sentAt : null,
    seenAt: isRead && latestReadAt != null
        ? DateTime.fromMillisecondsSinceEpoch(latestReadAt)
        : null,
  );
}

Message applyOutboundStatus(
  Message message, {
  required OutboundMessageStatus status,
  bool failed = false,
}) {
  final meta = <String, Object?>{...?message.metadata};
  if (failed) {
    meta['failed'] = true;
  } else {
    meta.remove('failed');
  }
  if (status.isPending) {
    meta['deliveryStatus'] = 'pending';
  } else if (status.isRead) {
    meta['deliveryStatus'] = 'read';
  } else if (status.isDelivered) {
    meta['deliveryStatus'] = 'sent';
  } else {
    meta.remove('deliveryStatus');
  }

  return message.copyWith(
    sentAt: status.sentAt,
    seenAt: status.seenAt,
    metadata: meta.isEmpty ? null : meta,
  );
}

bool isOutboundPending(Message message) =>
    message.metadata?['deliveryStatus'] == 'pending' ||
    (message.sentAt == null &&
        message.seenAt == null &&
        message.metadata?['failed'] != true);

bool isOutboundDelivered(Message message) =>
    !isOutboundPending(message) &&
    message.metadata?['failed'] != true &&
    (message.metadata?['deliveryStatus'] == 'sent' || message.sentAt != null);

bool isOutboundRead(Message message, {required bool readReceiptsEnabled}) =>
    readReceiptsEnabled &&
    !isOutboundPending(message) &&
    (message.metadata?['deliveryStatus'] == 'read' || message.seenAt != null);

/// UI tick state for outgoing messages (clock → single tick → double tick).
enum OutboundTickState { pending, delivered, read, failed }

OutboundTickState outboundTickState(
  Message message, {
  required bool readReceiptsEnabled,
}) {
  if (message.metadata?['failed'] == true) {
    return OutboundTickState.failed;
  }
  if (isOutboundPending(message)) {
    return OutboundTickState.pending;
  }
  if (isOutboundRead(message, readReceiptsEnabled: readReceiptsEnabled)) {
    return OutboundTickState.read;
  }
  if (isOutboundDelivered(message)) {
    return OutboundTickState.delivered;
  }
  return OutboundTickState.pending;
}

Message messageWithPendingStatus(Message message) {
  return message.copyWith(
    sentAt: null,
    seenAt: null,
    metadata: {
      ...?message.metadata,
      'failed': false,
      'deliveryStatus': 'pending',
    },
  );
}

Message messageWithDeliveryUpdate(
  Message message, {
  required String status,
  required bool readReceiptsEnabled,
}) {
  if (status == 'pending') {
    return message.copyWith(
      sentAt: null,
      seenAt: null,
      metadata: {
        ...?message.metadata,
        'failed': false,
        'deliveryStatus': 'pending',
      },
    );
  }
  if (status == 'sent') {
    final meta = <String, Object?>{...?message.metadata};
    meta.remove('failed');
    meta['deliveryStatus'] = 'sent';
    return message.copyWith(
      sentAt: DateTime.now(),
      seenAt: null,
      metadata: meta,
    );
  }
  if (status == 'read' && readReceiptsEnabled) {
    return message.copyWith(
      sentAt: message.sentAt ?? DateTime.now(),
      seenAt: DateTime.now(),
      metadata: {
        ...?message.metadata,
        'deliveryStatus': 'read',
      },
    );
  }
  if (status == 'failed') {
    final meta = <String, Object?>{...?message.metadata};
    meta.remove('deliveryStatus');
    meta['failed'] = true;
    return message.copyWith(metadata: meta);
  }
  return message;
}
