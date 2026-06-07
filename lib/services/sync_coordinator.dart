import 'dart:async';

import 'package:prysm/constants/group_constants.dart';
import 'package:prysm/services/chat_service.dart';
import 'package:prysm/services/group_chat_service.dart';
import 'package:prysm/services/message_modify_service.dart';
import 'package:prysm/services/reaction_service.dart';
import 'package:prysm/services/group_service.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/pending_message_db_helper.dart';
import 'package:prysm/util/pending_activity_notifier.dart';
import 'package:prysm/util/tor_service.dart';

/// Unified offline sync: pending delivery retries and adaptive sidebar refresh triggers.
class SyncCoordinator {
  final String userId;
  final KeyManager keyManager;
  final TorManager torManager;
  final bool Function() isTorStopped;

  Timer? _tickTimer;
  bool _flushing = false;
  bool _hasPendingBacklog = false;

  SyncCoordinator({
    required this.userId,
    required this.keyManager,
    required this.torManager,
    required this.isTorStopped,
  });

  void dispose() {
    _tickTimer?.cancel();
    _tickTimer = null;
  }

  Duration get _tickInterval {
    if (_hasPendingBacklog) return const Duration(seconds: 10);
    return const Duration(seconds: 30);
  }

  void start() {
    _tickTimer?.cancel();
    _scheduleTick(_tickInterval);
  }

  void _scheduleTick(Duration interval) {
    _tickTimer?.cancel();
    _tickTimer = Timer(interval, () async {
      await _onTick();
      if (_tickTimer != null) {
        _scheduleTick(_tickInterval);
      }
    });
  }

  Future<void> _onTick() async {
    if (isTorStopped()) return;
    await flushAllPending();
  }

  /// Flush all outbound pending queues. Returns true if anything was delivered.
  Future<bool> flushAllPending() async {
    if (isTorStopped() || _flushing) return false;
    _flushing = true;
    try {
      await _refreshPendingBacklogFlag();

      final groupService = GroupService(userId: userId, keyManager: keyManager);
      var any = false;

      any = await groupService.processPendingControlMessages() || any;
      any = await GroupChatService.processGlobalPending(
            userId: userId,
            keyManager: keyManager,
          ) ||
          any;
      any = await ReactionService.processGlobalPendingGroup(
            userId: userId,
            keyManager: keyManager,
          ) ||
          any;
      any = await ReactionService.processGlobalPendingDirect(
            userId: userId,
            keyManager: keyManager,
          ) ||
          any;
      any = await MessageModifyService.processGlobalPendingGroup(
            userId: userId,
            keyManager: keyManager,
          ) ||
          any;
      any = await MessageModifyService.processGlobalPendingDirect(
            userId: userId,
            keyManager: keyManager,
          ) ||
          any;
      any = await ChatService.processGlobalPending(
            userId: userId,
            keyManager: keyManager,
          ) ||
          any;

      await _refreshPendingBacklogFlag();
      if (any) {
        PendingActivityNotifier.instance.notify();
      }
      return any;
    } finally {
      _flushing = false;
    }
  }

  Future<void> _refreshPendingBacklogFlag() async {
    final all = await PendingMessageDbHelper.getAllPendingMessages();
    final outbound = all.where((m) {
      final type = m['type'] as String?;
      if (type == null) return false;
      if (isGroupControlType(type) || type == groupHistoryRelayType) {
        return m['senderId'] == userId;
      }
      if (isReactionType(type)) {
        return m['senderId'] == userId;
      }
      if (m['groupId'] != null) {
        return m['senderId'] == userId && isGroupMessageType(type);
      }
      return m['groupId'] == null && m['senderId'] == userId;
    });
    _hasPendingBacklog = outbound.isNotEmpty;
  }

  /// Call when Tor transitions to connected — immediate flush.
  Future<bool> onTorReconnected() async {
    return flushAllPending();
  }

  /// Speed up ticks while backlog exists.
  void notifyPendingActivity() {
    _hasPendingBacklog = true;
    start();
  }
}
