import 'package:prysm/models/chat/prysm_message.dart';
import 'package:prysm/models/group.dart';
import 'package:prysm/util/group_moderation_policy.dart';

const Duration messageEditWindow = Duration(minutes: 5);

bool isMessageDeleted(Message message) =>
    message.metadata?['deleted'] == true;

bool canEditMessage(Message message, String currentUserId) {
  if (isMessageDeleted(message)) return false;
  if (message.authorId != currentUserId) return false;
  if (message is! TextMessage) return false;
  final createdAt = message.createdAt;
  if (createdAt == null) return false;
  return DateTime.now().difference(createdAt) <= messageEditWindow;
}

bool canDeleteForEveryone(
  Message message,
  String currentUserId, {
  GroupRole? actorRole,
  GroupRole? authorRole,
}) {
  if (isMessageDeleted(message)) return false;
  if (message.authorId == currentUserId) return true;
  if (actorRole == null) return false;
  return canModerationDelete(
    actor: actorRole,
    author: authorRole ?? GroupRole.member,
  );
}

bool canForwardMessage(Message message) {
  if (isMessageDeleted(message)) return false;
  if (message is PrysmCallMessage) return false;
  if (message.metadata?['viewOnce'] == true) return false;
  return message is TextMessage ||
      message is ImageMessage ||
      message is FileMessage;
}

bool canPinMessage(Message message) => canForwardMessage(message);

Map<String, Object?> metadataFromDbRow(Map<String, dynamic> row) {
  final meta = <String, Object?>{};
  if (row['deletedAt'] != null) meta['deleted'] = true;
  if (row['editedAt'] != null) meta['edited'] = true;
  if (row['expiresAt'] != null) meta['expiresAt'] = row['expiresAt'];
  if ((row['forwarded'] ?? 0) == 1) meta['forwarded'] = true;
  return meta;
}

bool rowShowsAsDeleted(Map<String, dynamic> row, Map<String, dynamic> meta) {
  return meta['deleted'] == true;
}

Message markMessageDeleted(Message message) {
  final meta = <String, Object?>{...?message.metadata, 'deleted': true};
  if (message is TextMessage) {
    return message.copyWith(text: '', metadata: meta);
  }
  if (message is ImageMessage) {
    return message.copyWith(source: '', size: 0, metadata: meta);
  }
  if (message is FileMessage) {
    return message.copyWith(source: '', size: 0, metadata: meta);
  }
  return message.copyWith(metadata: meta);
}
