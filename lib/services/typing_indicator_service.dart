import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:prysm/services/settings_service.dart';
import 'package:prysm/transport/transport_provider.dart';

typedef TypingSendFn = Future<void> Function(
  String peerOnion,
  Map<String, dynamic> payload,
);

/// Sends debounced typing_update frames over WebSocket.
class TypingIndicatorService {
  static const _idleStopDelay = Duration(seconds: 3);
  static const _refreshInterval = Duration(seconds: 3);
  static const _throttleInterval = Duration(seconds: 2);

  final String userId;
  final String? peerId;
  final String? groupId;
  final List<String>? memberIds;
  final SettingsService _settings;
  final TypingSendFn? _sendOverride;

  bool _isTyping = false;
  Timer? _idleTimer;
  Timer? _refreshTimer;
  DateTime? _lastSentAt;
  bool _disposed = false;

  TypingIndicatorService.direct({
    required this.userId,
    required String peerId,
    SettingsService? settings,
    TypingSendFn? sendOverride,
  })  : peerId = peerId,
        groupId = null,
        memberIds = null,
        _settings = settings ?? SettingsService(),
        _sendOverride = sendOverride;

  TypingIndicatorService.group({
    required this.userId,
    required String groupId,
    required List<String> memberIds,
    SettingsService? settings,
    TypingSendFn? sendOverride,
  })  : peerId = null,
        groupId = groupId,
        memberIds = List<String>.from(memberIds),
        _settings = settings ?? SettingsService(),
        _sendOverride = sendOverride;

  bool get isGroup => groupId != null;

  void onComposerTypingChanged(bool isTyping) {
    if (_disposed) return;
    if (!_settings.enableTypingIndicators) return;

    if (!isTyping) {
      _stopTyping();
      return;
    }

    if (!_isTyping) {
      _isTyping = true;
      unawaited(_sendTyping(true));
    }

    _idleTimer?.cancel();
    _idleTimer = Timer(_idleStopDelay, _stopTyping);

    _refreshTimer ??= Timer.periodic(_refreshInterval, (_) {
      if (_isTyping) {
        unawaited(_sendTyping(true));
      }
    });
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _stopTyping();
  }

  void _stopTyping() {
    _idleTimer?.cancel();
    _idleTimer = null;
    _refreshTimer?.cancel();
    _refreshTimer = null;
    if (_isTyping) {
      _isTyping = false;
      unawaited(_sendTyping(false));
    }
  }

  Future<void> _sendTyping(bool typing) async {
    if (!_settings.enableTypingIndicators) return;

    final now = DateTime.now();
    if (typing &&
        _lastSentAt != null &&
        now.difference(_lastSentAt!) < _throttleInterval) {
      return;
    }
    _lastSentAt = now;

    final timestamp = now.millisecondsSinceEpoch;
    if (isGroup) {
      final targets = memberIds!
          .where((memberId) => memberId != userId)
          .toList(growable: false);
      for (final target in targets) {
        await _sendToPeer(
          target,
          {
            'senderId': userId,
            'receiverId': target,
            'groupId': groupId,
            'typing': typing,
            'timestamp': timestamp,
          },
        );
      }
      return;
    }

    await _sendToPeer(
      peerId!,
      {
        'senderId': userId,
        'receiverId': peerId,
        'typing': typing,
        'timestamp': timestamp,
      },
    );
  }

  Future<void> _sendToPeer(
    String peerOnion,
    Map<String, dynamic> payload,
  ) async {
    final send = _sendOverride;
    if (send != null) {
      await send(peerOnion, payload);
      return;
    }

    if (!TransportProvider.isConfigured) return;
    final manager = TransportProvider.instance.wsManager;
    if (!manager.isConnected(peerOnion)) return;

    try {
      await manager.send(peerOnion, 'typing_update', payload: payload);
    } catch (_) {
      // Typing is best-effort when the socket is unavailable.
    }
  }

  @visibleForTesting
  bool get isTypingActive => _isTyping;
}
