import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:prysm/services/call/call_manager.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/util/notification_service.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

abstract class CallForegroundSessionPort {
  bool get inCall;
  Future<void> sync(CallSnapshot snapshot, {CallSnapshot? previous});
  Future<void> onAppLifecycleChanged(AppLifecycleState state);
}

/// Keeps Tor/WS/audio viable while a call is in progress (foreground or background).
class CallForegroundSession implements CallForegroundSessionPort {
  CallForegroundSession._();

  static CallForegroundSessionPort? testOverride;
  static final CallForegroundSession _defaultInstance = CallForegroundSession._();

  static CallForegroundSessionPort get instance =>
      testOverride ?? _defaultInstance;

  static bool get isActive => instance.inCall;

  static void Function(bool inCall)? onActiveChanged;

  static void resetState() {
    testOverride = null;
    _defaultInstance._active = false;
    _defaultInstance._lastSnapshot = null;
  }

  bool _active = false;
  CallSnapshot? _lastSnapshot;

  @override
  bool get inCall => _active;

  @override
  Future<void> sync(
    CallSnapshot snapshot, {
    CallSnapshot? previous,
  }) async {
    _lastSnapshot = snapshot;
    final wasInCall = previous?.isInCall ?? false;
    final isInCall = snapshot.isInCall;

    if (isInCall && !wasInCall) {
      await _onEnterCall(snapshot);
    } else if (!isInCall && wasInCall) {
      await _onLeaveCall();
    } else if (isInCall) {
      await _onCallUpdate(snapshot, previous);
    }
  }

  Future<void> _onEnterCall(CallSnapshot snapshot) async {
    _setActive(true);
    if (snapshot.state == CallState.incoming) {
      await _syncIncomingCallNotification(snapshot);
    } else if (snapshot.state == CallState.active) {
      await _showActiveCallNotificationIfBackgrounded(snapshot);
    }
  }

  Future<void> _onLeaveCall() async {
    _setActive(false);
    await NotificationService().cancelCallNotifications();
    if (Platform.isAndroid) {
      await WakelockPlus.disable();
    }
  }

  Future<void> _onCallUpdate(
    CallSnapshot snapshot,
    CallSnapshot? previous,
  ) async {
    if (snapshot.state == CallState.incoming &&
        previous?.state != CallState.incoming) {
      await _syncIncomingCallNotification(snapshot);
      return;
    }

    if (snapshot.state == CallState.active) {
      await NotificationService().cancelIncomingCallNotification();
      await _showActiveCallNotificationIfBackgrounded(snapshot);
      if (Platform.isAndroid) {
        await WakelockPlus.enable();
      }
      return;
    }

    if (previous?.state == CallState.incoming) {
      await NotificationService().cancelIncomingCallNotification();
    }
  }

  void _setActive(bool value) {
    if (_active == value) return;
    _active = value;
    onActiveChanged?.call(value);
  }

  Future<void> _syncIncomingCallNotification(
    CallSnapshot snapshot, {
    AppLifecycleState? lifecycle,
  }) async {
    if (snapshot.state != CallState.incoming) return;
    final peerOnion = snapshot.peerOnion;
    final callId = snapshot.callId;
    if (peerOnion == null || callId == null) return;

    final effectiveLifecycle =
        lifecycle ?? WidgetsBinding.instance.lifecycleState;
    if (effectiveLifecycle == AppLifecycleState.resumed) {
      await NotificationService().cancelIncomingCallNotification();
      return;
    }

    final displayName = await _peerDisplayName(peerOnion);
    await NotificationService().showIncomingCall(
      peerOnion: peerOnion,
      callId: callId,
      displayName: displayName,
    );
  }

  @override
  Future<void> onAppLifecycleChanged(AppLifecycleState state) async {
    final snapshot = _lastSnapshot;
    if (snapshot == null) return;

    if (snapshot.state == CallState.incoming) {
      await _syncIncomingCallNotification(snapshot, lifecycle: state);
      return;
    }

    if (snapshot.state != CallState.active) return;
    switch (state) {
      case AppLifecycleState.resumed:
        await NotificationService().cancelActiveCallNotification();
      case AppLifecycleState.paused:
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
        await _showActiveCallNotification(_lastSnapshot!);
      case AppLifecycleState.detached:
        break;
    }
  }

  Future<void> _showActiveCallNotificationIfBackgrounded(
    CallSnapshot snapshot,
  ) async {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle == AppLifecycleState.resumed) return;
    await _showActiveCallNotification(snapshot);
  }

  Future<void> _showActiveCallNotification(CallSnapshot snapshot) async {
    final peerOnion = snapshot.peerOnion;
    final callId = snapshot.callId;
    if (peerOnion == null || callId == null) return;

    final displayName = await _peerDisplayName(peerOnion);
    await NotificationService().showActiveCall(
      peerOnion: peerOnion,
      callId: callId,
      displayName: displayName,
    );
  }

  Future<String> _peerDisplayName(String peerOnion) async {
    final row = await DBHelper.getUserById(peerOnion);
    final name = row?['name'] as String?;
    if (name != null && name.isNotEmpty) return name;
    if (peerOnion.length <= 16) return peerOnion;
    return '${peerOnion.substring(0, 16)}…';
  }
}
