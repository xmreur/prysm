import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:prysm/services/settings_service.dart';

class TypingIndicatorEvent {
  final String senderId;
  final String? groupId;
  final String? peerId;
  final bool typing;
  final int timestamp;

  const TypingIndicatorEvent({
    required this.senderId,
    required this.groupId,
    required this.peerId,
    required this.typing,
    required this.timestamp,
  });
}

/// Broadcasts ephemeral typing events received over WebSocket.
class TypingIndicatorNotifier {
  TypingIndicatorNotifier._();

  static final TypingIndicatorNotifier instance = TypingIndicatorNotifier._();

  final _controller = StreamController<TypingIndicatorEvent>.broadcast();

  Stream<TypingIndicatorEvent> get events => _controller.stream;

  @visibleForTesting
  void resetForTest() {
    // StreamController is not reset; tests should listen before emit.
  }

  void applyInbound(Map<String, dynamic> payload) {
    if (!SettingsService().enableTypingIndicators) return;

    final senderId = payload['senderId'];
    if (senderId is! String || senderId.isEmpty) return;

    final typing = payload['typing'];
    if (typing is! bool) return;

    final timestamp = payload['timestamp'];
    final groupId = payload['groupId'];

    _controller.add(
      TypingIndicatorEvent(
        senderId: senderId,
        groupId: groupId is String && groupId.isNotEmpty ? groupId : null,
        peerId: groupId == null || (groupId is String && groupId.isEmpty)
            ? senderId
            : null,
        typing: typing,
        timestamp: timestamp is int ? timestamp : DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }
}
