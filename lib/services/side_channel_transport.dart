import 'dart:async';

import 'package:prysm/services/pending_side_channel_queue.dart';
import 'package:prysm/services/side_channel_postman.dart';
import 'package:prysm/util/tor_delivery.dart';

/// Shared transport layer for the three side-channel services:
/// reactions, read receipts, and message modifications.
///
/// The module is instantiated with an explicit [userId], [outbox] and
/// [postman]; it does not use any global singletons. It encapsulates:
///
/// * direct and group delivery with [TorDelivery] retry policy;
/// * insertion into the pending side-channel queue on failure;
/// * global and per-peer flush of pending side-channel rows.
///
/// Higher-level services remain responsible for payload construction,
/// encryption, and database side effects; they only call this module for
/// the duplicated "send and retry" logic.
class SideChannelTransport {
  final String userId;
  final SideChannelOutbox outbox;
  final SideChannelPostman postman;
  final int maxAttempts;
  final void Function(String context, Object error)? onDeliveryError;

  SideChannelTransport({
    required this.userId,
    required this.outbox,
    required this.postman,
    this.maxAttempts = 3,
    this.onDeliveryError,
  });

  /// Sends a direct side-channel payload to [peerId].
  ///
  /// Returns `true` if delivery succeeded, `false` otherwise. The caller
  /// decides whether to queue the message for later retry.
  Future<bool> sendDirect({
    required String id,
    required String peerId,
    required String encrypted,
    required int timestamp,
    required String type,
    bool fastFail = false,
  }) async {
    if (peerId.isEmpty) return false;
    final payload = _buildDirectPayload(
      id: id,
      peerId: peerId,
      encrypted: encrypted,
      timestamp: timestamp,
      type: type,
    );
    return _postDirect(
      payload: payload,
      peerId: peerId,
      fastFail: fastFail,
    );
  }

  /// Sends a direct side-channel payload and enqueues it on failure.
  Future<bool> sendDirectAndQueue({
    required String id,
    required String peerId,
    required String encrypted,
    required int timestamp,
    required String type,
    bool fastFail = false,
  }) async {
    final ok = await sendDirect(
      id: id,
      peerId: peerId,
      encrypted: encrypted,
      timestamp: timestamp,
      type: type,
      fastFail: fastFail,
    );
    if (ok) return true;
    await outbox.insertDirect(
      id: id,
      senderId: userId,
      receiverId: peerId,
      message: encrypted,
      type: type,
      timestamp: timestamp,
    );
    return false;
  }

  /// Sends a group side-channel payload to a single [targetMemberId].
  ///
  /// Each group member is a separate call; the caller iterates over members.
  Future<bool> sendGroup({
    required String id,
    required String groupId,
    required String targetMemberId,
    required String encrypted,
    required int timestamp,
    required String type,
    bool fastFail = false,
  }) async {
    if (groupId.isEmpty || targetMemberId.isEmpty) return false;
    final payload = _buildGroupPayload(
      id: id,
      groupId: groupId,
      targetMemberId: targetMemberId,
      encrypted: encrypted,
      timestamp: timestamp,
      type: type,
    );
    return _postGroup(
      payload: payload,
      targetMemberId: targetMemberId,
      fastFail: fastFail,
    );
  }

  /// Sends a group side-channel payload to one member and enqueues on failure.
  Future<bool> sendGroupAndQueue({
    required String id,
    required String groupId,
    required String targetMemberId,
    required String encrypted,
    required int timestamp,
    required String type,
    bool fastFail = false,
  }) async {
    final ok = await sendGroup(
      id: id,
      groupId: groupId,
      targetMemberId: targetMemberId,
      encrypted: encrypted,
      timestamp: timestamp,
      type: type,
      fastFail: fastFail,
    );
    if (ok) return true;
    await outbox.insertGroup(
      id: id,
      senderId: userId,
      receiverId: targetMemberId,
      message: encrypted,
      type: type,
      timestamp: timestamp,
      groupId: groupId,
      targetMemberId: targetMemberId,
    );
    return false;
  }

  /// Retries pending side-channel rows for a specific peer.
  ///
  /// Only [types] that match the side-channel set of the caller are processed.
  /// Returns `true` if at least one row was delivered and removed.
  Future<bool> flushPendingForPeer({
    required String peerId,
    required Set<String> types,
    int? maxPerCycle,
  }) async {
    final rows = await outbox.getPendingDirectForReceiver(
      senderId: userId,
      receiverId: peerId,
      types: types,
      limit: maxPerCycle,
    );
    var any = false;
    for (final row in rows) {
      final receiverId = row.receiverId;
      if (receiverId == null || receiverId.isEmpty) continue;
      final ok = await sendDirect(
        id: row.id,
        peerId: receiverId,
        encrypted: row.message,
        timestamp: row.timestamp,
        type: row.type,
        fastFail: true,
      );
      if (ok) {
        await outbox.remove(row.id);
        any = true;
      }
    }
    return any;
  }

  /// Retries all pending direct side-channel rows for the current user.
  Future<bool> flushGlobalPendingDirect({
    required Set<String> types,
    int? maxPerCycle,
  }) async {
    final rows = await outbox.getPendingDirect(
      senderId: userId,
      types: types,
      limit: maxPerCycle,
    );
    var any = false;
    for (final row in rows) {
      final receiverId = row.receiverId;
      if (receiverId == null || receiverId.isEmpty) continue;
      final ok = await sendDirect(
        id: row.id,
        peerId: receiverId,
        encrypted: row.message,
        timestamp: row.timestamp,
        type: row.type,
        fastFail: true,
      );
      if (ok) {
        await outbox.remove(row.id);
        any = true;
      }
    }
    return any;
  }

  /// Retries all pending group side-channel rows for the current user.
  ///
  /// By default the wire id sent to the peer is the pending row's [id].
  /// Pass [wireIdOf] to derive a different wire id from the row (for
  /// example, to strip a suffix appended to make queue ids unique).
  Future<bool> flushGlobalPendingGroup({
    required Set<String> types,
    int? maxPerCycle,
    String Function(PendingSideChannel row)? wireIdOf,
  }) async {
    final rows = await outbox.getPendingGroup(
      senderId: userId,
      types: types,
      limit: maxPerCycle,
    );
    var any = false;
    for (final row in rows) {
      final groupId = row.groupId;
      final target = row.targetMemberId ?? row.receiverId;
      if (groupId == null || target == null || target.isEmpty) continue;
      final ok = await sendGroup(
        id: wireIdOf == null ? row.id : wireIdOf(row),
        groupId: groupId,
        targetMemberId: target,
        encrypted: row.message,
        timestamp: row.timestamp,
        type: row.type,
        fastFail: true,
      );
      if (ok) {
        await outbox.remove(row.id);
        any = true;
      }
    }
    return any;
  }

  Map<String, dynamic> _buildDirectPayload({
    required String id,
    required String peerId,
    required String encrypted,
    required int timestamp,
    required String type,
  }) {
    return {
      'id': id,
      'senderId': userId,
      'receiverId': peerId,
      'message': encrypted,
      'type': type,
      'timestamp': timestamp,
    };
  }

  Map<String, dynamic> _buildGroupPayload({
    required String id,
    required String groupId,
    required String targetMemberId,
    required String encrypted,
    required int timestamp,
    required String type,
  }) {
    return {
      'id': id,
      'senderId': userId,
      'receiverId': targetMemberId,
      'groupId': groupId,
      'message': encrypted,
      'type': type,
      'timestamp': timestamp,
    };
  }

  Future<bool> _postDirect({
    required Map<String, dynamic> payload,
    required String peerId,
    required bool fastFail,
  }) async {
    try {
      await TorDelivery.withTorRetry<void>(
        maxAttempts: fastFail ? 1 : maxAttempts,
        attempt: () => postman.postDirect(
          peerId: peerId,
          payload: payload,
        ),
      );
      return true;
    } catch (e) {
      onDeliveryError?.call('direct:$peerId', e);
      return false;
    }
  }

  Future<bool> _postGroup({
    required Map<String, dynamic> payload,
    required String targetMemberId,
    required bool fastFail,
  }) async {
    try {
      await TorDelivery.withTorRetry<void>(
        maxAttempts: fastFail ? 1 : maxAttempts,
        attempt: () => postman.postGroup(
          targetMemberId: targetMemberId,
          payload: payload,
        ),
      );
      return true;
    } catch (e) {
      onDeliveryError?.call('group:$targetMemberId', e);
      return false;
    }
  }
}
