import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:prysm/database/messages.dart';
import 'package:prysm/services/settings_service.dart';
import 'package:prysm/transport/transport_provider.dart';
import 'package:prysm/util/battery_saver_policy.dart';
import 'package:prysm/util/pending_message_db_helper.dart';

/// Lightweight delivery wake hints: notify recent peers to flush pending outbound
/// traffic toward this node when it becomes reachable over Tor.
class WakeHintService {
  WakeHintService._();
  static final WakeHintService instance = WakeHintService._();

  static const Duration _hintTimeout = Duration(seconds: 10);
  static const Duration _timestampSkewTolerance = Duration(minutes: 5);

  String? _userId;
  bool Function()? _isTorStopped;
  bool Function()? _showOnlineStatus;
  Future<bool> Function(String peerId)? _onFlushPeer;
  Future<bool> Function(String senderId)? _hasOutboundPendingForSender;

  final Map<String, DateTime> _lastSentToPeer = {};
  final Map<String, DateTime> _lastReceivedFromPeer = {};

  void configure({
    required String userId,
    required bool Function() isTorStopped,
    required bool Function() showOnlineStatus,
    required Future<bool> Function(String peerId) onFlushPeer,
    Future<bool> Function(String senderId)? hasOutboundPendingForSender,
  }) {
    _userId = userId;
    _isTorStopped = isTorStopped;
    _showOnlineStatus = showOnlineStatus;
    _onFlushPeer = onFlushPeer;
    _hasOutboundPendingForSender = hasOutboundPendingForSender;
  }

  /// Clears in-memory dedupe state (for tests).
  void resetForTest() {
    _lastSentToPeer.clear();
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
    final userId = _userId;
    if (userId == null || _isTorStopped?.call() == true) return;
    if (_showOnlineStatus?.call() != true) return;
    if (SettingsService().enableWebSocketTransport) return;

    final timestamps = await MessagesDb.getLastMessageTimestampsForAllUsers();
    final peers = timestamps.entries
        .where((e) => e.key != userId)
        .toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    final targets = peers
        .take(BatterySaverPolicy.wakeHintMaxPeers)
        .map((e) => e.key)
        .where(_canSendToPeer)
        .toList();

    if (targets.isEmpty) return;

    final random = Random();
    final staggerMin = BatterySaverPolicy.wakeHintStaggerMin().inMilliseconds;
    final staggerMax = BatterySaverPolicy.wakeHintStaggerMax().inMilliseconds;

    for (var i = 0; i < targets.length; i++) {
      if (_isTorStopped?.call() == true) break;
      if (i > 0) {
        final delayMs = staggerMin +
            random.nextInt(max(1, staggerMax - staggerMin + 1));
        await Future.delayed(Duration(milliseconds: delayMs));
      }
      await _sendHintToPeer(userId, targets[i]);
    }
  }

  bool _canSendToPeer(String peerId) {
    final lastSent = _lastSentToPeer[peerId];
    if (lastSent == null) return true;
    return DateTime.now().difference(lastSent) >=
        BatterySaverPolicy.wakeHintSendCooldown;
  }

  Future<void> _sendHintToPeer(String userId, String peerId) async {
    if (TransportProvider.isConfigured &&
        TransportProvider.instance.isRealtimeConnected(peerId)) {
      return;
    }
    try {
      await TransportProvider.postJsonOrFallback(
        peerOnion: peerId,
        path: 'sync-hint',
        payload: {
          'senderId': userId,
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        },
        timeout: _hintTimeout,
      );
      _lastSentToPeer[peerId] = DateTime.now();
    } catch (e) {
      debugPrint('Wake hint send to $peerId failed: $e');
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
