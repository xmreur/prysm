import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:prysm/services/image_attachment_cache.dart';
import 'package:prysm/util/pending_message_db_helper.dart';

/// Removes ciphertext and media artifacts for a message id.
class MessageContentWiper {
  MessageContentWiper._();

  static Future<void> wipeLocalArtifacts({
    required String wireId,
    String? groupId,
  }) async {
    await PendingMessageDbHelper.removeOutboundPendingForWireId(
      wireId,
      groupId: groupId,
    );
    await ImageAttachmentCache.invalidate(wireId);
    await _deleteVoiceCaches(wireId);
  }

  static Future<void> _deleteVoiceCaches(String messageId) async {
    try {
      final dir = await getTemporaryDirectory();
      for (final name in [
        'voice_cache_$messageId.wav',
        'group_voice_cache_$messageId.wav',
      ]) {
        final file = File('${dir.path}/$name');
        if (await file.exists()) {
          await file.delete();
        }
      }
    } catch (_) {}
  }
}
