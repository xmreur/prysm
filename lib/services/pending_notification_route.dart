import 'dart:convert';

/// Parsed target for opening a chat from a notification tap.
class PendingNotificationRoute {
  final String senderId;
  final String? groupId;
  final String? conversationType;

  const PendingNotificationRoute({
    required this.senderId,
    this.groupId,
    this.conversationType,
  });

  bool get isGroup => groupId != null && groupId!.isNotEmpty;

  static PendingNotificationRoute? fromPayload(String? payload) {
    if (payload == null || payload.isEmpty) return null;
    try {
      final data = jsonDecode(payload) as Map<String, dynamic>;
      final senderId = data['senderId'];
      if (senderId is! String || senderId.isEmpty) return null;
      final groupId = data['groupId'];
      return PendingNotificationRoute(
        senderId: senderId,
        groupId: groupId is String && groupId.isNotEmpty ? groupId : null,
        conversationType: data['conversationType'] as String?,
      );
    } catch (_) {
      return null;
    }
  }

  String toPayload() => jsonEncode({
        'senderId': senderId,
        if (groupId != null) 'groupId': groupId,
        if (conversationType != null) 'conversationType': conversationType,
      });
}

/// Holds a notification tap until [HomeScreen] can navigate.
class PendingNotificationRouteStore {
  PendingNotificationRouteStore._();

  static final PendingNotificationRouteStore instance =
      PendingNotificationRouteStore._();

  PendingNotificationRoute? _pending;

  void setFromPayload(String? payload) {
    final route = PendingNotificationRoute.fromPayload(payload);
    if (route != null) {
      _pending = route;
    }
  }

  void set(PendingNotificationRoute? route) {
    _pending = route;
  }

  PendingNotificationRoute? peek() => _pending;

  PendingNotificationRoute? take() {
    final route = _pending;
    _pending = null;
    return route;
  }

  void clear() {
    _pending = null;
  }
}
