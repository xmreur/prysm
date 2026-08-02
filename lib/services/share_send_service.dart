import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:prysm/models/contact.dart';
import 'package:prysm/models/group.dart';
import 'package:prysm/models/share_target.dart';
import 'package:prysm/models/shared_content.dart';
import 'package:prysm/services/detached_chat_bridge.dart';
import 'package:prysm/util/chat_attachment_ingress.dart';
import 'package:prysm/util/file_bytes_reader.dart';
import 'package:prysm/util/file_transfer_policy.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:uuid/uuid.dart';

class ShareSendResult {
  const ShareSendResult({
    required this.success,
    this.errorMessage,
  });

  final bool success;
  final String? errorMessage;
}

/// Sends shared OS content into a conversation without opening the chat UI.
class ShareSendService {
  ShareSendService._();

  static Future<ShareSendResult> send({
    required ShareTarget target,
    required SharedContent content,
    required String userId,
    required KeyManager keyManager,
    required List<Contact> contacts,
    required Group? Function(String groupId) groupById,
  }) async {
    final messageId = const Uuid().v4();
    final chatKind = target.kind;
    final conversationId = target.conversationId;

    if (content.isText) {
      final text = content.text?.trim() ?? '';
      if (text.isEmpty) {
        return const ShareSendResult(
          success: false,
          errorMessage: 'Nothing to send.',
        );
      }
      final sentId = await DetachedChatBridge.sendSharedText(
        chatKind: chatKind,
        conversationId: conversationId,
        text: text,
        messageId: messageId,
        userId: userId,
        keyManager: keyManager,
        contacts: contacts,
        groupById: groupById,
      );
      return ShareSendResult(
        success: sentId != null,
        errorMessage: sentId == null ? 'Could not send message.' : null,
      );
    }

    final path = content.filePath;
    if (path == null || path.isEmpty) {
      return const ShareSendResult(
        success: false,
        errorMessage: 'Shared file is unavailable.',
      );
    }

    final bytes = await readFileBytesDeferred(path);
    if (!FileTransferPolicy.isWithinMaxFileSize(bytes.length)) {
      return ShareSendResult(
        success: false,
        errorMessage: FileTransferPolicy.maxFileSizeError,
      );
    }

    final fileName = _resolveFileName(content);
    final isImage = ChatAttachmentIngress.isImageFileName(fileName) ||
        (content.mimeType?.startsWith('image/') ?? false);

    Uint8List payload = bytes;
    var type = 'file';
    if (isImage) {
      payload = await ChatAttachmentIngress.prepareImageBytes(bytes);
      if (!FileTransferPolicy.isWithinMaxFileSize(payload.length)) {
        return ShareSendResult(
          success: false,
          errorMessage: FileTransferPolicy.maxFileSizeError,
        );
      }
      type = 'image';
    }

    final sentId = await DetachedChatBridge.sendSharedFile(
      chatKind: chatKind,
      conversationId: conversationId,
      bytes: payload,
      fileName: fileName,
      type: type,
      messageId: messageId,
      userId: userId,
      keyManager: keyManager,
      contacts: contacts,
      groupById: groupById,
    );

    return ShareSendResult(
      success: sentId != null,
      errorMessage: sentId == null ? 'Could not send file.' : null,
    );
  }

  static String _resolveFileName(SharedContent content) {
    final fromContent = content.fileName?.trim();
    if (fromContent != null && fromContent.isNotEmpty) {
      return fromContent;
    }
    final path = content.filePath;
    if (path == null || path.isEmpty) return 'shared_file';
    final base = p.basename(Uri.parse(path).path);
    return base.isEmpty ? 'shared_file' : base;
  }
}
