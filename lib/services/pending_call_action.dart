import 'dart:convert';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

enum CallNotificationAction { accept, decline, hangup, open }

/// Parsed target for a call notification tap or action button.
class PendingCallAction {
  const PendingCallAction({
    required this.action,
    required this.callId,
    required this.peerOnion,
  });

  final CallNotificationAction action;
  final String callId;
  final String peerOnion;

  static PendingCallAction? fromPayload(String? payload) {
    if (payload == null || payload.isEmpty) return null;
    try {
      final data = jsonDecode(payload) as Map<String, dynamic>;
      if (data['type'] != 'call') return null;
      final callId = data['callId'];
      final peerOnion = data['peerOnion'];
      if (callId is! String ||
          callId.isEmpty ||
          peerOnion is! String ||
          peerOnion.isEmpty) {
        return null;
      }
      final action = _parseAction(data['action']);
      if (action == null) return null;
      return PendingCallAction(
        action: action,
        callId: callId,
        peerOnion: peerOnion,
      );
    } catch (_) {
      return null;
    }
  }

  static PendingCallAction? fromResponse(NotificationResponse response) {
    final parsed = PendingCallAction.fromPayload(response.payload);
    if (parsed == null) return null;
    final actionId = response.actionId;
    if (actionId == null || actionId.isEmpty) return parsed;
    final mapped = _parseAction(actionId);
    if (mapped == null) return parsed;
    return PendingCallAction(
      action: mapped,
      callId: parsed.callId,
      peerOnion: parsed.peerOnion,
    );
  }

  static CallNotificationAction? _parseAction(dynamic raw) {
    return switch (raw) {
      'accept' => CallNotificationAction.accept,
      'decline' => CallNotificationAction.decline,
      'hangup' => CallNotificationAction.hangup,
      'open' => CallNotificationAction.open,
      _ => null,
    };
  }

  String toPayload() => jsonEncode({
        'type': 'call',
        'action': switch (action) {
          CallNotificationAction.accept => 'accept',
          CallNotificationAction.decline => 'decline',
          CallNotificationAction.hangup => 'hangup',
          CallNotificationAction.open => 'open',
        },
        'callId': callId,
        'peerOnion': peerOnion,
      });
}

/// Holds a call notification action until [HomeScreen] can handle it.
class PendingCallActionStore {
  PendingCallActionStore._();

  static final PendingCallActionStore instance = PendingCallActionStore._();

  PendingCallAction? _pending;

  void setFromPayload(String? payload) {
    final action = PendingCallAction.fromPayload(payload);
    if (action != null) {
      _pending = action;
    }
  }

  void set(PendingCallAction? action) {
    _pending = action;
  }

  PendingCallAction? peek() => _pending;

  PendingCallAction? take() {
    final action = _pending;
    _pending = null;
    return action;
  }

  void clear() {
    _pending = null;
  }
}
