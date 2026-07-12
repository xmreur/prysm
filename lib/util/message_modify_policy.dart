import 'package:prysm/models/chat/prysm_message.dart';

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

bool canDeleteForEveryone(Message message, String currentUserId) {
  if (isMessageDeleted(message)) return false;
  return message.authorId == currentUserId;
}

Map<String, Object?> metadataFromDbRow(Map<String, dynamic> row) {
  final meta = <String, Object?>{};
  if (row['deletedAt'] != null) meta['deleted'] = true;
  if (row['editedAt'] != null) meta['edited'] = true;
  return meta;
}

const Set<String> _deferredWireMessageTypes = {
  'file',
  'image',
  'audio',
  'group_file',
  'group_image',
  'group_audio',
};

/// List queries may omit the huge [message] column; attachments load wire lazily.
bool rowShowsAsDeleted(Map<String, dynamic> row, Map<String, dynamic> meta) {
  if (meta['deleted'] == true) return true;
  final type = row['type'] as String?;
  if (type != null && _deferredWireMessageTypes.contains(type)) {
    return false;
  }
  final wire = row['message'];
  return wire == null || (wire is String && wire.isEmpty);
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
