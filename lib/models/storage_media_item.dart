import 'package:prysm/constants/group_constants.dart';
import 'package:prysm/database/message_id_codec.dart';
import 'package:prysm/models/chat_media_item.dart';

/// A media row in the global storage browser with conversation context.
class StorageMediaItem {
  final String id;
  final String type;
  final String? fileName;
  final int? fileSize;
  final int timestamp;
  final String senderId;
  final bool isViewOnce;
  final bool viewed;
  final bool isGroup;
  final String? groupId;
  final String? peerId;
  final String conversationLabel;

  const StorageMediaItem({
    required this.id,
    required this.type,
    required this.fileName,
    required this.fileSize,
    required this.timestamp,
    required this.senderId,
    required this.isViewOnce,
    required this.viewed,
    required this.isGroup,
    required this.groupId,
    required this.peerId,
    required this.conversationLabel,
  });

  bool get isImage => type == 'image' || type == groupImageType;
  bool get isVoice => type == 'audio' || type == groupAudioType;
  bool get isFile => type == 'file' || type == groupFileType;

  ChatMediaItem toChatMediaItem() {
    return ChatMediaItem(
      id: id,
      type: type,
      fileName: fileName,
      fileSize: fileSize,
      timestamp: timestamp,
      senderId: senderId,
      isViewOnce: isViewOnce,
      viewed: viewed,
      isGroup: isGroup,
    );
  }

  factory StorageMediaItem.fromRow(
    Map<String, dynamic> row, {
    required String userId,
    required Map<String, String> contactNames,
    required Map<String, String> groupNames,
  }) {
    final groupId = row['groupId'] as String?;
    final isGroup = groupId != null;
    final senderId = row['senderId'] as String;
    final receiverId = row['receiverId'] as String;

    final peerId = isGroup
        ? null
        : (senderId == userId ? receiverId : senderId);

    final conversationLabel = isGroup
        ? (groupNames[groupId] ?? 'Group')
        : (contactNames[peerId] ?? peerId ?? 'Chat');

    return StorageMediaItem(
      id: MessageIdCodec.wireIdFromStorage(row['id'] as String),
      type: row['type'] as String,
      fileName: row['fileName'] as String?,
      fileSize: row['fileSize'] as int?,
      timestamp: row['timestamp'] as int,
      senderId: senderId,
      isViewOnce: (row['viewOnce'] ?? 0) == 1,
      viewed: (row['viewed'] ?? 0) == 1,
      isGroup: isGroup,
      groupId: groupId,
      peerId: peerId,
      conversationLabel: conversationLabel,
    );
  }
}

/// Maps gallery tabs to message types across direct and group chats.
List<String>? globalTypesForFilter(ChatMediaFilter filter) {
  switch (filter) {
    case ChatMediaFilter.all:
      return null;
    case ChatMediaFilter.photos:
      return ['image', groupImageType];
    case ChatMediaFilter.files:
      return ['file', groupFileType];
    case ChatMediaFilter.voice:
      return ['audio', groupAudioType];
  }
}
