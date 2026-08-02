import 'package:prysm/database/messages.dart';
import 'package:prysm/util/conversation_refresh_notifier.dart';
import 'package:prysm/util/disappearing_activity_notifier.dart';
import 'package:prysm/util/logging.dart';
import 'package:prysm/util/message_content_wiper.dart';
import 'package:prysm/util/message_modify_refresh_notifier.dart';

/// Permanently removes messages whose [expiresAt] has passed.
class DisappearingMessagePurgeService {
  DisappearingMessagePurgeService._();
  static final DisappearingMessagePurgeService instance =
      DisappearingMessagePurgeService._();

  bool _purging = false;

  Future<DateTime?> nextExpiryAt() async {
    final at = await MessagesDb.getNextExpiresAt();
    return at == null ? null : DateTime.fromMillisecondsSinceEpoch(at);
  }

  Future<int> purgeDue({DateTime? now}) async {
    if (_purging) return 0;
    _purging = true;
    try {
      final cutoff = (now ?? DateTime.now()).millisecondsSinceEpoch;
      final due = await MessagesDb.getExpiredMessages(cutoff: cutoff);
      if (due.isEmpty) return 0;

      final removedAt = DateTime.now().millisecondsSinceEpoch;
      for (final row in due) {
        final storageId = row['id'] as String;
        final wireId = MessagesDb.wireIdFromStorage(storageId);
        final groupId = row['groupId'] as String?;
        try {
          await MessageContentWiper.wipeLocalArtifacts(
            wireId: wireId,
            groupId: groupId,
          );
          await MessagesDb.hardDeleteMessage(wireId, groupId: groupId);
          MessageModifyRefreshNotifier.instance.notify(
            MessageModifyUpdate(
              targetMessageId: wireId,
              action: 'remove',
              modifiedAt: removedAt,
            ),
          );
        } catch (e) {
          Logging.error(
            'Failed to purge expired message $wireId: $e',
            'DisappearingMessagePurgeService',
          );
        }
      }
      DisappearingActivityNotifier.instance.notify();
      ConversationRefreshNotifier.instance.notifyInboundMessage();
      return due.length;
    } finally {
      _purging = false;
    }
  }
}
