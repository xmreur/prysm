import 'package:prysm/constants/group_constants.dart';
import 'package:prysm/database/messages.dart';

String notificationTitleForInbound({
  required bool isGroup,
  required String senderName,
  String? groupName,
}) {
  if (isGroup) {
    return groupName?.isNotEmpty == true ? groupName! : 'Group chat';
  }
  return senderName;
}

String notificationBodyForInbound({
  required String type,
  required bool isGroup,
  required String senderName,
  bool viewOnce = false,
}) {
  if (viewOnce) {
    return isGroup
        ? '$senderName sent a view-once message'
        : 'Open to view the message';
  }

  if (type == 'text' || type == groupTextType) {
    return isGroup ? '$senderName: New message' : 'New message';
  }

  final preview = MessagesDb.previewLabelForType(type);
  return isGroup ? '$senderName: $preview' : preview;
}

String truncateNotificationBody(String body, {int maxLength = 80}) {
  if (body.length <= maxLength) return body;
  return '${body.substring(0, maxLength - 1)}…';
}
