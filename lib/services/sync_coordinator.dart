import 'dart:async';

import 'package:prysm/constants/group_constants.dart';
import 'package:prysm/services/chat_service.dart';
import 'package:prysm/services/group_chat_service.dart';
import 'package:prysm/services/message_modify_service.dart';
import 'package:prysm/services/reaction_service.dart';
import 'package:prysm/services/read_receipt_service.dart';
import 'package:prysm/services/group_service.dart';
import 'package:prysm/services/scheduled_message_service.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/logging.dart';
import 'package:prysm/util/pending_message_db_helper.dart';
import 'package:prysm/util/pending_activity_notifier.dart';
import 'package:prysm/util/scheduled_activity_notifier.dart';
import 'package:prysm/util/battery_saver_policy.dart';
import 'package:prysm/util/tor_runtime_gate.dart';
import 'package:prysm/util/tor_service.dart';

/// Unified offline sync: pending delivery retries and adaptive sidebar refresh triggers.
class SyncCoordinator {
  final String userId;
  final KeyManager keyManager;
  final TorManager torManager;
  final bool Function() isTorStopped;

  /// Longest a send timer is armed for. Scheduled messages can sit for weeks,
  /// so the wait is chopped into hops that recompute the remaining delay —
  /// which also absorbs suspends and clock changes.
  static const Duration _maxArmDelay = Duration(hours: 1);

  Timer? _tickTimer;
  Timer? _pendingFlushDebounce;
  Timer? _scheduledTimer;
  StreamSubscription<void>? _pendingActivitySub;
  StreamSubscription<void>? _scheduledActivitySub;
  bool _flushing = false;
  bool _hasPendingBacklog = false;
  bool _disposed = false;

  /// Bumped on every arm request so a slower in-flight arm loses to a newer one
  /// instead of leaving a stale timer behind.
  int _armGeneration = 0;

  SyncCoordinator({
    required this.userId,
    required this.keyManager,
    required this.torManager,
    required this.isTorStopped,
  }) : _scheduledMessages = ScheduledMessageService(
          userId: userId,
          keyManager: keyManager,
        );

  final ScheduledMessageService _scheduledMessages;

  void dispose() {
    _tickTimer?.cancel();
    _tickTimer = null;
    _pendingFlushDebounce?.cancel();
    _pendingFlushDebounce = null;
    _scheduledTimer?.cancel();
    _scheduledTimer = null;
    _pendingActivitySub?.cancel();
    _pendingActivitySub = null;
    _scheduledActivitySub?.cancel();
    _scheduledActivitySub = null;
    _disposed = true;
  }

  Duration get _tickInterval {
    if (_hasPendingBacklog) return BatterySaverPolicy.syncTickBacklog();
    return BatterySaverPolicy.syncTickIdle();
  }

  void start() {
    _tickTimer?.cancel();
    _scheduleTick(_tickInterval);
    _pendingActivitySub ??=
        PendingActivityNotifier.instance.onChanged.listen((_) {
      _hasPendingBacklog = true;
      _pendingFlushDebounce?.cancel();
      _pendingFlushDebounce = Timer(const Duration(milliseconds: 750), () {
        unawaited(flushAllPending());
      });
    });
    _scheduledActivitySub ??=
        ScheduledActivityNotifier.instance.onChanged.listen((_) {
      // A message was just scheduled or cancelled: the earliest due time moved,
      // so re-aim the timer rather than waiting out the old one.
      unawaited(_armScheduledTimer());
    });
    unawaited(_armScheduledTimer());
  }

  /// Arms a one-shot timer for the moment the next scheduled message is due.
  ///
  /// Kept off [flushAllPending] on purpose: that method holds [_flushing] for
  /// as long as the retry queues take, and a single unreachable peer can stall
  /// them for minutes. A scheduled message must go out at its time regardless.
  Future<void> _armScheduledTimer({Duration? minDelay}) async {
    final generation = ++_armGeneration;
    _scheduledTimer?.cancel();
    _scheduledTimer = null;
    if (_disposed) return;

    final DateTime? next;
    try {
      next = await _scheduledMessages.nextDueAt();
    } catch (e) {
      Logging.error(
        'Could not read next scheduled time: $e',
        'SyncCoordinator',
      );
      return;
    }
    if (_disposed || generation != _armGeneration) return;
    // Nothing queued; ScheduledActivityNotifier re-arms us on the next insert.
    if (next == null) return;

    var wait = next.difference(DateTime.now());
    if (wait.isNegative) wait = Duration.zero;
    if (minDelay != null && wait < minDelay) wait = minDelay;
    if (wait > _maxArmDelay) wait = _maxArmDelay;

    _scheduledTimer = Timer(wait, () => unawaited(_flushScheduled()));
  }

  Future<void> _flushScheduled() async {
    try {
      if (TorRuntimeGate.blocked || isTorStopped()) return;
      if (await _scheduledMessages.flushDue()) {
        PendingActivityNotifier.instance.notify();
      }
    } catch (e) {
      Logging.error('Scheduled flush failed: $e', 'SyncCoordinator');
    } finally {
      // A row still due after this attempt means Tor is down or the send
      // failed, so hold off instead of re-firing on an already-past time.
      await _armScheduledTimer(
        minDelay: BatterySaverPolicy.scheduledMessageRetry(),
      );
    }
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
    if (TorRuntimeGate.blocked || isTorStopped()) return;
    await flushAllPending();
  }

  /// Flush all outbound pending queues. Returns true if anything was delivered.
  Future<bool> flushAllPending() async {
    if (TorRuntimeGate.blocked || isTorStopped() || _flushing) return false;
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
      any = await ChatService.processGlobalPending(
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
      any = await ReadReceiptService.processGlobalPendingGroup(
            userId: userId,
            keyManager: keyManager,
          ) ||
          any;
      any = await ReadReceiptService.processGlobalPendingDirect(
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
      if (isReactionType(type) || isReadReceiptType(type)) {
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
    // Scheduled sends get their own kick: anything that came due while Tor was
    // down should not have to wait for the retry queues to finish first.
    unawaited(_armScheduledTimer());
    return flushAllPending();
  }

  /// Flush outbound pending queues for one direct peer (wake-hint response).
  Future<bool> flushPendingForPeer(String receiverId) async {
    if (TorRuntimeGate.blocked || isTorStopped() || _flushing) return false;

    final hasPending = await PendingMessageDbHelper.hasOutboundDirectPending(
      userId,
      receiverId,
    );
    if (!hasPending) return false;

    _flushing = true;
    try {
      var any = false;

      any = await ChatService.processPendingForPeer(
            userId: userId,
            peerId: receiverId,
            keyManager: keyManager,
          ) ||
          any;
      any = await ReadReceiptService.processPendingForPeer(
            userId: userId,
            peerId: receiverId,
            keyManager: keyManager,
          ) ||
          any;
      any = await ReactionService.processPendingForPeer(
            userId: userId,
            peerId: receiverId,
            keyManager: keyManager,
          ) ||
          any;
      any = await MessageModifyService.processPendingForPeer(
            userId: userId,
            peerId: receiverId,
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

  /// Speed up ticks while backlog exists.
  void notifyPendingActivity() {
    _hasPendingBacklog = true;
    start();
  }
}
