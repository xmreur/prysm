import 'package:prysm/database/message_reactions.dart';
import 'package:prysm/database/messages.dart';
import 'package:prysm/models/chat/prysm_message.dart';
import 'package:prysm/models/group.dart';
import 'package:prysm/services/message_modify_service.dart';
import 'package:prysm/util/message_content_wiper.dart';
import 'package:prysm/util/message_modify_policy.dart';
import 'package:prysm/util/message_status_mapper.dart';
import 'package:prysm/util/pending_message_db_helper.dart';

/// Which delete branch [MessageActionsService.deleteMessage] took, so the
/// caller can apply the matching UI-model update.
enum MessageDeleteOutcome {
  /// The message was still queued outbound (never sent): its pending-queue
  /// row, DB row, and reactions were all removed. Only reachable when the
  /// service was built with a non-null `cancelPendingSend` (direct chats).
  removedPending,

  /// The message was tombstoned via [MessageModifyService] (sender can
  /// delete-for-everyone): the DB row stays, only its reactions are wiped.
  markedDeletedForEveryone,

  /// Delete-for-everyone was applied locally (tombstone + reaction wipe),
  /// but the modify was not delivered to the peer right now: the send failed
  /// (unknown peer identity / no group key, transport error, or a 4xx/5xx
  /// rejection). The modify is queued for a later retry when the failure was
  /// transient; either way the peer has not confirmed the delete, so the
  /// caller should surface the send-failure state.
  markedDeletedForEveryoneFailed,

  /// Local-only delete: artifacts wiped, DB row and reactions removed.
  removedLocally,
}

/// Orchestrates message delete/edit against `MessagesDb`, `MessageReactionsDb`,
/// `PendingMessageDbHelper`, and `MessageContentWiper` (Fase 6A extraction of
/// the near-identical `_deleteMessage`/`_deleteSelectedMessages`/`_editMessage`
/// code that used to live inline in `_ChatScreenState` and
/// `_GroupChatScreenState`).
///
/// One implementation for both direct chats and groups: pass [groupId] to
/// scope storage ids/wiped artifacts to a group, and [cancelPendingSend] to
/// enable the pending-outbound-message delete branch (direct chats only —
/// groups never surface a locally-pending message for delete today).
class MessageActionsService {
  MessageActionsService({
    required this.modifyService,
    this.groupId,
    this.cancelPendingSend,
  });

  final MessageModifyService modifyService;
  final String? groupId;
  final void Function(String wireId)? cancelPendingSend;

  String _storageId(String wireId) =>
      MessagesDb.scopedId(wireId: wireId, groupId: groupId);

  /// Deletes [message], picking the same branch the original per-screen
  /// `_deleteMessage` implementations picked:
  /// 1. still-pending outbound (direct chats only, when [cancelPendingSend]
  ///    was supplied) → drop the pending-queue row and cancel the in-flight
  ///    send before wiping;
  /// 2. sender can delete-for-everyone → remote tombstone + local reaction
  ///    cleanup, DB row kept;
  /// 3. otherwise → local-only wipe.
  Future<MessageDeleteOutcome> deleteMessage(
    Message message, {
    required String localUserId,
    GroupRole? actorRole,
    GroupRole? authorRole,
  }) async {
    if (cancelPendingSend != null &&
        message.authorId == localUserId &&
        isOutboundPending(message)) {
      await _deletePendingMessage(message.id);
      return MessageDeleteOutcome.removedPending;
    }

    if (canDeleteForEveryone(
      message,
      localUserId,
      actorRole: actorRole,
      authorRole: authorRole,
    )) {
      final propagated = await modifyService.deleteMessage(
        targetMessageId: message.id,
      );
      await MessageReactionsDb.deleteReactionsForMessage(
        _storageId(message.id),
      );
      return propagated
          ? MessageDeleteOutcome.markedDeletedForEveryone
          : MessageDeleteOutcome.markedDeletedForEveryoneFailed;
    }

    await _deleteLocalOnly(message.id);
    return MessageDeleteOutcome.removedLocally;
  }

  Future<void> _deletePendingMessage(String wireId) async {
    await PendingMessageDbHelper.removeOutboundPendingForWireId(
      wireId,
      groupId: groupId,
    );
    cancelPendingSend?.call(wireId);
    await MessageContentWiper.wipeLocalArtifacts(
      wireId: wireId,
      groupId: groupId,
    );
    await MessagesDb.deleteMessageById(_storageId(wireId));
    await MessageReactionsDb.deleteReactionsForMessage(_storageId(wireId));
  }

  Future<void> _deleteLocalOnly(String wireId) async {
    await MessageContentWiper.wipeLocalArtifacts(
      wireId: wireId,
      groupId: groupId,
    );
    await MessagesDb.deleteMessageById(_storageId(wireId));
    await MessageReactionsDb.deleteReactionsForMessage(_storageId(wireId));
  }

  /// Edits [message]'s text via [MessageModifyService]. Returns the updated
  /// message (with `metadata['edited'] = true`) on success, or `null` if the
  /// remote edit failed and the caller should show an error.
  Future<TextMessage?> editTextMessage(
    TextMessage message,
    String newText,
  ) async {
    final ok = await modifyService.editTextMessage(
      targetMessageId: message.id,
      newText: newText,
    );
    if (!ok) return null;
    return message.copyWith(
      text: newText,
      metadata: {...?message.metadata, 'edited': true},
    );
  }
}
