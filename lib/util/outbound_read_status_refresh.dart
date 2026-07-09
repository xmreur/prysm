import 'package:prysm/models/chat/prysm_message.dart';
import 'package:prysm/database/message_read_receipts.dart';
import 'package:prysm/util/message_status_mapper.dart';

Map<String, dynamic> dbRowFromOutboundMessage(
  Message message,
  String localUserId,
) {
  final deliveryStatus = message.metadata?['deliveryStatus'] as String?;
  final isFailed = message.metadata?['failed'] == true;
  final isPending = !isFailed &&
      (deliveryStatus == 'pending' || isOutboundPending(message));

  return {
    'senderId': localUserId,
    'status': isPending ? 'pending' : 'sent',
    'timestamp': message.createdAt?.millisecondsSinceEpoch ?? 0,
  };
}

/// Applies read receipt data to [messages] without hitting the database.
List<Message> applyReadStatusFromReceipts({
  required List<Message> messages,
  required String localUserId,
  required bool readReceiptsEnabled,
  required Map<String, List<Map<String, dynamic>>> receiptsByWireId,
  int requiredReadCount = 1,
}) {
  if (!readReceiptsEnabled) return messages;

  return messages.map((message) {
    if (message.authorId != localUserId) return message;

    final isFailed = message.metadata?['failed'] == true;
    final row = dbRowFromOutboundMessage(message, localUserId);
    final status = outboundStatusFromDbRow(
      row: row,
      localUserId: localUserId,
      readReceiptsEnabled: readReceiptsEnabled,
      receipts: receiptsByWireId[message.id] ?? const [],
      requiredReadCount: requiredReadCount,
    );

    return applyOutboundStatus(message, status: status, failed: isFailed);
  }).toList();
}

/// Re-derives outbound tick/read state from [message_read_receipts] for visible messages.
Future<List<Message>> refreshOutboundReadStatus({
  required List<Message> messages,
  required String localUserId,
  required bool readReceiptsEnabled,
  String? groupId,
  int requiredReadCount = 1,
}) async {
  if (!readReceiptsEnabled || messages.isEmpty) return messages;

  final outboundWireIds = messages
      .where((m) => m.authorId == localUserId)
      .map((m) => m.id)
      .toList();
  if (outboundWireIds.isEmpty) return messages;

  final receipts = await MessageReadReceiptsDb.getReceiptsForMessages(
    outboundWireIds,
    groupId: groupId,
  );

  return applyReadStatusFromReceipts(
    messages: messages,
    localUserId: localUserId,
    readReceiptsEnabled: readReceiptsEnabled,
    receiptsByWireId: receipts,
    requiredReadCount: requiredReadCount,
  );
}
