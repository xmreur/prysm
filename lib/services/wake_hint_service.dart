import 'dart:async';
import 'dart:math';

import 'package:prysm/database/messages.dart';
import 'package:prysm/transport/transport_provider.dart';
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
  final Map<String, DateTime> _lastBroadcastToPeer = {};
  DateTime? _lastBroadcastAt;

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
    _lastBroadcastToPeer.clear();
    _lastBroadcastAt = null;
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
    final userId = _userId;
    if (userId == null || userId.isEmpty) return;
    if (!TransportProvider.isConfigured) return;

    final now = DateTime.now();
    if (_lastBroadcastAt != null &&
        now.difference(_lastBroadcastAt!) <
            BatterySaverPolicy.wakeHintSendCooldown) {
      return;
    }
    _lastBroadcastAt = now;

    Set<String> peers;
    try {
      final timestamps = await MessagesDb.getLastMessageTimestampsForAllUsers();
      final recent = timestamps.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      peers = recent
          .take(BatterySaverPolicy.wakeHintMaxPeers)
          .map((e) => e.key)
          .where((id) => id != userId)
          .toSet();
    } catch (_) {
      return;
    }

    if (peers.isEmpty) return;

    final rng = Random();
    final staggerMin = BatterySaverPolicy.wakeHintStaggerMin().inMilliseconds;
    final staggerMax = BatterySaverPolicy.wakeHintStaggerMax().inMilliseconds;

    for (final peer in peers) {
      final last = _lastBroadcastToPeer[peer];
      if (last != null &&
          now.difference(last) < BatterySaverPolicy.wakeHintSendCooldown) {
        continue;
      }
      _lastBroadcastToPeer[peer] = now;

      unawaited(
        TransportProvider.postSyncHint(peerOnion: peer, senderId: userId),
      );

      if (staggerMax > 0) {
        final delayMs = staggerMin +
            (staggerMax > staggerMin
                ? rng.nextInt(staggerMax - staggerMin)
                : 0);
        await Future.delayed(Duration(milliseconds: delayMs));
      }
    }
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

    if (TransportProvider.isConfigured) {
      unawaited(
        TransportProvider.instance.wsManager
            .ensureConnected(senderId)
            .catchError((_) {}),
      );
    }

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
