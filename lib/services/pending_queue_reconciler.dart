import 'package:prysm/constants/group_constants.dart';
import 'package:prysm/database/messages.dart';
import 'package:prysm/util/logging.dart';
import 'package:prysm/util/pending_message_db_helper.dart';

/// Reconciles the 1:1 chat pending-message queue and drives the
/// best-effort single-pass flush used by the wake-hint / global-sync
/// retry paths.
///
/// Extracted from [ChatService] (Fase 3.2). The live-polling drain with
/// per-message backoff (`_processSendQueue`) stays on `ChatService` —
/// that is "invio" (send orchestration), not queue bookkeeping. This
/// module owns only:
///  - re-queuing outbound rows dropped from the pending table
///    (`reconcile`, was `reconcilePendingQueue`);
///  - the best-effort single pass used by `processPendingForPeer` /
///    `processGlobalPending` (`flushOnce`, was `_processPendingOnce`).
/// Delivery itself is delegated back to the caller via [sendPending] so
/// this module never touches transport, encryption, or chunking.
class PendingQueueReconciler {
  final String userId;
  final String peerId;

  /// True once the owning ChatService has been disposed.
  final bool Function() isDisposed;

  /// True once the owning ChatService has a resolved peer identity.
  final bool Function() hasPeerIdentity;

  /// True if [wireId] currently has an in-flight send attempt.
  final bool Function(String wireId) isInFlight;

  /// Re-encrypts and re-queues [wireId] without triggering a queue drain.
  final Future<void> Function(String wireId) requeue;

  /// Attempts one delivery of a pending row; returns success.
  final Future<bool> Function(Map<String, dynamic> pendingRow) sendPending;

  /// Marks a message as sent (DB + status stream).
  final Future<void> Function(String messageId) markAsSent;

  PendingQueueReconciler({
    required this.userId,
    required this.peerId,
    required this.isDisposed,
    required this.hasPeerIdentity,
    required this.isInFlight,
    required this.requeue,
    required this.sendPending,
    required this.markAsSent,
  });

  /// Re-queues outbound messages that show as pending in the UI but were
  /// dropped from the pending_messages retry table (e.g. after a failed
  /// send before the queue insert, or app restart during a long Tor
  /// timeout).
  Future<void> reconcile() async {
    if (isDisposed() || !hasPeerIdentity()) return;

    final pendingRows = await MessagesDb.getPendingOutboundDirectMessages(
      senderId: userId,
      receiverId: peerId,
    );
    if (pendingRows.isEmpty) return;

    for (final row in pendingRows) {
      if (isDisposed() || !hasPeerIdentity()) return;

      final wireId = MessagesDb.wireIdFromStorage(row['id'] as String);
      final type = row['type'] as String? ?? 'text';
      if (isSideChannelPendingType(type)) continue;
      if (isInFlight(wireId)) continue;

      final queued =
          await PendingMessageDbHelper.getPendingOutboundForWireId(wireId);
      if (queued != null) continue;

      try {
        await requeue(wireId);
      } catch (e) {
        Logging.error(
          'Failed to re-queue pending message $wireId: $e',
          'PendingQueueReconciler',
        );
      }
    }
  }

  /// Best-effort single pass over this peer's pending queue: attempts up
  /// to 10 rows once each via [sendPending] and stops at the first
  /// failure (the caller retries on the next wake-hint / sync cycle).
  Future<void> flushOnce() async {
    final pending =
        await PendingMessageDbHelper.getPendingMessages(receiverId: peerId);
    if (pending.isEmpty || !hasPeerIdentity()) return;

    final sentIds = <String>[];
    for (final msg in pending.take(10)) {
      if (isDisposed()) break;

      final type = msg['type'] as String?;
      if (type != null && isSideChannelPendingType(type)) {
        continue;
      }

      final msgId = msg['id'] as String;
      final stored = await MessagesDb.getMessageById(msgId);
      if (stored.isEmpty || stored.first['deletedAt'] != null) {
        await PendingMessageDbHelper.removeOutboundPendingForWireId(msgId);
        continue;
      }

      final encrypted = msg['message'] as String?;
      if (encrypted == null || encrypted.isEmpty) {
        await PendingMessageDbHelper.removeOutboundPendingForWireId(msgId);
        continue;
      }

      final success = await sendPending(msg);
      if (success) {
        sentIds.add(msgId);
        await markAsSent(msgId);
      } else {
        break;
      }
    }
    if (sentIds.isNotEmpty) {
      await PendingMessageDbHelper.removeMessages(sentIds);
    }
  }

  /// Chat-only pending rows for [receiverId] (excludes reaction/receipt/
  /// message-modify side channels, which retry through their own
  /// transport). Mirrors the early-exit check in
  /// `ChatService.processPendingForPeer`.
  static Future<List<Map<String, dynamic>>> chatPendingForReceiver({
    required String senderId,
    required String receiverId,
  }) async {
    final pending = await PendingMessageDbHelper.getPendingDirectMessagesForReceiver(
      senderId: senderId,
      receiverId: receiverId,
    );
    return pending.where((m) {
      final type = m['type'] as String?;
      if (type == null) return false;
      return !isSideChannelPendingType(type);
    }).toList();
  }

  /// Peers with at least one pending direct-message row (unfiltered by
  /// type — mirrors the existing early-exit check in
  /// `ChatService.processGlobalPending`).
  static Future<Set<String>> peersWithPendingDirectMessages({
    required String senderId,
    int? limit,
  }) async {
    final pending = await PendingMessageDbHelper.getPendingDirectMessages(
      senderId: senderId,
      limit: limit,
    );
    return pending
        .map((m) => m['receiverId'] as String?)
        .whereType<String>()
        .where((id) => id.isNotEmpty)
        .toSet();
  }
}
