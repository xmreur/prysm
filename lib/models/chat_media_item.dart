import 'package:prysm/constants/group_constants.dart';
import 'package:prysm/database/messages.dart';

/// A media attachment row surfaced in the in-chat gallery.
class ChatMediaItem {
  final String id;
  final String type;
  final String? fileName;
  final int? fileSize;
  final int timestamp;
  final String senderId;
  final bool isViewOnce;
  final bool viewed;
  final bool isGroup;

  const ChatMediaItem({
    required this.id,
    required this.type,
    required this.fileName,
    required this.fileSize,
    required this.timestamp,
    required this.senderId,
    required this.isViewOnce,
    required this.viewed,
    required this.isGroup,
  });

  bool get isImage => type == 'image' || type == groupImageType;
  bool get isVoice => type == 'audio' || type == groupAudioType;
  bool get isFile => type == 'file' || type == groupFileType;

  factory ChatMediaItem.fromRow(
    Map<String, dynamic> row, {
    required bool isGroup,
  }) {
    return ChatMediaItem(
      id: MessagesDb.wireIdFromStorage(row['id'] as String),
      type: row['type'] as String,
      fileName: row['fileName'] as String?,
      fileSize: row['fileSize'] as int?,
      timestamp: row['timestamp'] as int,
      senderId: row['senderId'] as String,
      isViewOnce: (row['viewOnce'] ?? 0) == 1,
      viewed: (row['viewed'] ?? 0) == 1,
      isGroup: isGroup,
    );
  }
}

/// Tab filter for the gallery screen.
enum ChatMediaFilter {
  all,
  photos,
  files,
  voice,
}

String? dbTypeForFilter(ChatMediaFilter filter, {required bool isGroup}) {
  switch (filter) {
    case ChatMediaFilter.all:
      return null;
    case ChatMediaFilter.photos:
      return isGroup ? groupImageType : 'image';
    case ChatMediaFilter.files:
      return isGroup ? groupFileType : 'file';
    case ChatMediaFilter.voice:
      return isGroup ? groupAudioType : 'audio';
  }
}
