import 'package:flutter_chat_core/flutter_chat_core.dart';
import 'package:prysm/constants/group_constants.dart';
import 'package:prysm/database/messages.dart';
import 'package:prysm/models/reply_preview_data.dart';
import 'package:prysm/util/message_modify_policy.dart';

ReplyPreviewData replyPreviewFromMessage(Message message) {
  if (isMessageDeleted(message)) {
    return ReplyPreviewData(
      messageId: message.id,
      authorId: message.authorId,
      label: 'Deleted',
      kind: ReplyPreviewKind.deleted,
    );
  }

  if (message is TextMessage) {
    return ReplyPreviewData(
      messageId: message.id,
      authorId: message.authorId,
      label: message.text,
      kind: ReplyPreviewKind.text,
    );
  }

  if (message is ImageMessage) {
    return ReplyPreviewData(
      messageId: message.id,
      authorId: message.authorId,
      label: 'Photo',
      kind: ReplyPreviewKind.image,
    );
  }

  if (message is FileMessage) {
    if (_isVoiceMessage(message)) {
      return ReplyPreviewData(
        messageId: message.id,
        authorId: message.authorId,
        label: 'Voice message',
        kind: ReplyPreviewKind.voice,
      );
    }
    return ReplyPreviewData(
      messageId: message.id,
      authorId: message.authorId,
      label: message.name,
      kind: ReplyPreviewKind.file,
    );
  }

  return ReplyPreviewData(
    messageId: message.id,
    authorId: message.authorId,
    label: 'Message',
    kind: ReplyPreviewKind.text,
  );
}

ReplyPreviewData replyPreviewFromDbRow(Map<String, dynamic> row) {
  final id = MessagesDb.wireIdFromStorage(row['id'] as String);
  final authorId = row['senderId'] as String?;
  if (row['deletedAt'] != null) {
    return ReplyPreviewData(
      messageId: id,
      authorId: authorId,
      label: 'Deleted',
      kind: ReplyPreviewKind.deleted,
    );
  }

  final type = row['type'] as String?;
  final fileName = row['fileName'] as String?;

  if (type == 'image' || type == groupImageType) {
    return ReplyPreviewData(
      messageId: id,
      authorId: authorId,
      label: 'Photo',
      kind: ReplyPreviewKind.image,
    );
  }

  if (type == 'audio' || type == groupAudioType || _isVoiceFileName(fileName)) {
    return ReplyPreviewData(
      messageId: id,
      authorId: authorId,
      label: 'Voice message',
      kind: ReplyPreviewKind.voice,
    );
  }

  if (type == 'file' || type == groupFileType) {
    return ReplyPreviewData(
      messageId: id,
      authorId: authorId,
      label: fileName ?? 'File',
      kind: ReplyPreviewKind.file,
    );
  }

  if (type == 'text' || type == groupTextType) {
    return ReplyPreviewData(
      messageId: id,
      authorId: authorId,
      label: 'Message',
      kind: ReplyPreviewKind.text,
    );
  }

  return ReplyPreviewData(
    messageId: id,
    authorId: authorId,
    label: MessagesDb.previewLabelForType(type),
    kind: ReplyPreviewKind.text,
  );
}

bool _isVoiceMessage(FileMessage message) {
  return message.name.contains('voice_message') ||
      message.source.startsWith('audio:');
}

bool _isVoiceFileName(String? fileName) {
  return fileName != null && fileName.contains('voice_message');
}
