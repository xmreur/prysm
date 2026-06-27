import 'dart:async';

import 'package:prysm/util/battery_saver_policy.dart';
import 'package:prysm/util/pending_message_db_helper.dart';

/// Lightweight delivery wake hints: notify recent peers to flush pending outbound
/// traffic toward this node when it becomes reachable over Tor.
class WakeHintService {
  WakeHintService._();
  static final WakeHintService instance = WakeHintService._();

  static const Duration _timestampSkewTolerance = Duration(minutes: 5);

  String? _userId;
  Future<bool> Function(String peerId)? _onFlushPeer;
  Future<bool> Function(String senderId)? _hasOutboundPendingForSender;

  final Map<String, DateTime> _lastReceivedFromPeer = {};

  void configure({
    required String userId,
    required Future<bool> Function(String peerId) onFlushPeer,
    Future<bool> Function(String senderId)? hasOutboundPendingForSender,
  }) {
    _userId = userId;
    _onFlushPeer = onFlushPeer;
    _hasOutboundPendingForSender = hasOutboundPendingForSender;
  }

  /// Clears in-memory dedupe state (for tests).
  void resetForTest() {
    _lastReceivedFromPeer.clear();
  }

  /// Validates sync-hint payload. Returns null when valid, or an error message.
  static String? validateSyncHintPayload(
    Map<String, dynamic> data,
    String? localOnionAddress,
  ) {
    final senderId = data['senderId'];
    final timestamp = data['timestamp'];
    if (senderId is! String || senderId.isEmpty) {
      return 'senderId required';
    }
    if (timestamp is! int) {
      return 'timestamp required';
    }
    if (localOnionAddress != null && senderId == localOnionAddress) {
      return 'self wake rejected';
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    if ((now - timestamp).abs() > _timestampSkewTolerance.inMilliseconds) {
      return 'timestamp out of range';
    }
    return null;
  }

  Future<void> broadcastRecentPeerHints() async {
    // Persistent WebSocket connections replace HTTP wake hints.
  }

  Future<void> handleIncomingHint(String senderId) async {
    final userId = _userId;
    if (userId == null || senderId.isEmpty) return;

    final lastReceived = _lastReceivedFromPeer[senderId];
    if (lastReceived != null &&
        DateTime.now().difference(lastReceived) <
            BatterySaverPolicy.wakeHintReceiveDebounce) {
      return;
    }
    _lastReceivedFromPeer[senderId] = DateTime.now();

    final hasPending = await _hasPendingForSender(senderId);
    if (!hasPending) return;

    await _onFlushPeer?.call(senderId);
  }

  Future<bool> _hasPendingForSender(String senderId) async {
    final custom = _hasOutboundPendingForSender;
    if (custom != null) return custom(senderId);
    final userId = _userId;
    if (userId == null) return false;
    return PendingMessageDbHelper.hasOutboundDirectPending(userId, senderId);
  }
}
