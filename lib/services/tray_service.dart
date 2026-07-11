import 'package:flutter/widgets.dart';
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:prysm/database/messages.dart';
import 'package:prysm/services/battery_saver_service.dart';
import 'package:prysm/services/call/call_foreground_session.dart';
import 'package:prysm/services/call/call_manager.dart';
import 'package:prysm/services/settings_service.dart';
import 'package:prysm/util/battery_saver_policy.dart';
import 'package:prysm/util/conversation_refresh_notifier.dart';
import 'package:prysm/util/logging.dart';
import 'package:prysm/util/pending_activity_notifier.dart';
import 'package:prysm/util/pending_message_db_helper.dart';
import 'package:prysm/util/tor_bootstrap_notifier.dart';
import 'package:prysm/util/tor_connection_notifier.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

class TrayStatus {
  final String torLabel;
  final int pendingCount;
  final int unreadTotal;
  final bool inCall;

  const TrayStatus({
    required this.torLabel,
    required this.pendingCount,
    required this.unreadTotal,
    this.inCall = false,
  });

  String formatTooltip() {
    final parts = <String>['Prysm', 'Tor $torLabel'];
    if (inCall) {
      parts.add('In call');
    }
    if (pendingCount > 0) {
      parts.add('$pendingCount pending');
    }
    if (unreadTotal > 0) {
      parts.add('$unreadTotal unread');
    }
    return parts.join(' · ');
  }
}

/// Desktop system tray: hide-to-tray, status tooltip/menu, unread badge.
class TrayService with TrayListener {
  TrayService._();
  static final TrayService instance = TrayService._();

  static bool get _isDesktop =>
      !Platform.isAndroid && !Platform.isIOS;

  bool _initialized = false;
  bool _started = false;
  String? _userId;

  Timer? _pollTimer;
  Timer? _unreadDebounce;
  StreamSubscription<int>? _bootstrapSub;
  StreamSubscription<TorConnectionState>? _torSub;
  StreamSubscription<void>? _pendingSub;
  StreamSubscription<void>? _refreshSub;
  StreamSubscription<void>? _batterySaverSub;
  VoidCallback? _callManagerListener;

  int _lastUnread = -1;
  String? _badgedIconPath;

  bool get isEnabled =>
      _isDesktop && SettingsService().minimizeToTray;

  bool get shouldMinimizeOnMinimizeButton =>
      _isDesktop && SettingsService().minimizeOnMinimizeButton;

  Future<void> init() async {
    if (!_isDesktop || _initialized) return;
    _initialized = true;

    await windowManager.ensureInitialized();
    await _applyPreventClose();

    trayManager.addListener(this);
    await _setBaseIcon();
    await _rebuildMenu(const TrayStatus(
      torLabel: 'starting',
      pendingCount: 0,
      unreadTotal: 0,
    ));
    await _applyTooltip('Prysm');
  }

  Future<void> start({
    required String userId,
  }) async {
    if (!_isDesktop || _started) return;
    _started = true;
    _userId = userId;

    _bootstrapSub?.cancel();
    _bootstrapSub =
        TorBootstrapNotifier.instance.onProgress.listen((_) => refreshStatus());

    _torSub?.cancel();
    _torSub = TorConnectionNotifier.instance.onStateChanged
        .listen((_) => refreshStatus());

    _pendingSub?.cancel();
    _pendingSub =
        PendingActivityNotifier.instance.onChanged.listen((_) => refreshStatus());

    _refreshSub?.cancel();
    _refreshSub = ConversationRefreshNotifier.instance.onRefresh.listen((_) {
      _unreadDebounce?.cancel();
      _unreadDebounce = Timer(const Duration(milliseconds: 400), refreshStatus);
    });

    _batterySaverSub?.cancel();
    _batterySaverSub = BatterySaverService.instance.onChanged.listen((_) {
      _restartPollTimer();
    });

    CallForegroundSession.onActiveChanged = (_) {
      unawaited(refreshStatus());
    };

    _callManagerListener ??= () => unawaited(refreshStatus());
    try {
      CallManager.instance.addListener(_callManagerListener!);
    } catch (_) {}

    _restartPollTimer();
    await refreshStatus();
  }

  void _restartPollTimer() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(
      BatterySaverPolicy.trayPollInterval(),
      (_) => refreshStatus(),
    );
  }

  Future<void> applySettings() async {
    if (!_isDesktop) return;
    await _applyPreventClose();
  }

  Future<void> _applyPreventClose() async {
    await windowManager.setPreventClose(isEnabled);
  }

  Future<void> refreshStatus() async {
    if (!_isDesktop || !_started || _userId == null) return;

    final bootstrap = TorBootstrapNotifier.instance.progress;
    final torConn = TorConnectionNotifier.instance.state;
    final torLabel = _torLabel(bootstrap, torConn);

    final pending =
        await PendingMessageDbHelper.countOutboundPending(_userId!);
    final unreadMap = await MessagesDb.getUnreadCounts(_userId!);
    final unreadTotal =
        unreadMap.values.fold<int>(0, (sum, n) => sum + n);

    final status = TrayStatus(
      torLabel: torLabel,
      pendingCount: pending,
      unreadTotal: unreadTotal,
      inCall: CallForegroundSession.isActive,
    );

    await _applyTooltip(status.formatTooltip());
    await _updateIcon(unreadTotal);
    await _rebuildMenu(status);
  }

  /// Linux AppIndicator has no native tooltip; setTitle maps to SNI Title (hover).
  Future<void> _applyTooltip(String text) async {
    if (Platform.isLinux) {
      await trayManager.setTitle(text);
      return;
    }
    try {
      await trayManager.setToolTip(text);
    } catch (e) {
      if (kDebugMode) {
        Logging.error('Tray tooltip failed: $e', 'TrayService');
      }
    }
  }

  String _torLabel(int bootstrap, TorConnectionState conn) {
    if (bootstrap > 0 && bootstrap < 100) {
      return 'connecting ($bootstrap%)';
    }
    return switch (conn) {
      TorConnectionState.connected => 'connected',
      TorConnectionState.connecting => 'connecting',
      TorConnectionState.disconnected => 'off',
    };
  }

  Future<void> _setBaseIcon() async {
    if (Platform.isMacOS) {
      await trayManager.setIcon(
        'assets/tray/icon_template.png',
        isTemplate: true,
      );
    } else {
      await trayManager.setIcon('assets/tray/icon.png');
    }
  }

  Future<void> _updateIcon(int unreadTotal) async {
    if (unreadTotal <= 0) {
      if (_lastUnread > 0) {
        await _setBaseIcon();
      }
      _lastUnread = 0;
      return;
    }

    if (unreadTotal == _lastUnread && _badgedIconPath != null) {
      return;
    }
    _lastUnread = unreadTotal;

    if (Platform.isMacOS) {
      return;
    }

    final path = await _renderBadgedIcon(unreadTotal);
    if (path != null) {
      _badgedIconPath = path;
      await trayManager.setIcon(path);
    }
  }

  Future<String?> _renderBadgedIcon(int count) async {
    try {
      final data = await rootBundle.load('assets/tray/icon.png');
      final codec = await ui.instantiateImageCodec(
        data.buffer.asUint8List(),
      );
      final frame = await codec.getNextFrame();
      final image = frame.image;
      final w = image.width;
      final h = image.height;

      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawImage(image, Offset.zero, Paint());

      final badgeRadius = w * 0.22;
      final badgeCenter = Offset(w - badgeRadius, badgeRadius);
      canvas.drawCircle(
        badgeCenter,
        badgeRadius,
        Paint()..color = const Color(0xFFE53935),
      );
      canvas.drawCircle(
        badgeCenter,
        badgeRadius,
        Paint()
          ..color = const Color(0xFFFFFFFF)
          ..style = PaintingStyle.stroke
          ..strokeWidth = w * 0.04,
      );

      final label = count > 99 ? '99+' : '$count';
      final fontSize = badgeRadius * 1.1;
      final builder = ui.ParagraphBuilder(
        ui.ParagraphStyle(
          textAlign: TextAlign.center,
          fontSize: fontSize,
          fontWeight: FontWeight.bold,
        ),
      )
        ..pushStyle(ui.TextStyle(color: const Color(0xFFFFFFFF)))
        ..addText(label);
      final paragraph = builder.build()
        ..layout(ui.ParagraphConstraints(width: badgeRadius * 2));
      canvas.drawParagraph(
        paragraph,
        Offset(badgeCenter.dx - badgeRadius, badgeCenter.dy - fontSize * 0.55),
      );

      final picture = recorder.endRecording();
      final badged = await picture.toImage(w, h);
      final bytes =
          await badged.toByteData(format: ui.ImageByteFormat.png);
      if (bytes == null) return null;

      final file = File(
        '${(await getTemporaryDirectory()).path}/prysm_tray_badge.png',
      );
      await file.writeAsBytes(bytes.buffer.asUint8List(), flush: true);
      return file.path;
    } catch (e) {
       Logging.error('Tray badge render failed: $e', 'TrayService');

      return null;
    }
  }

  Future<void> _rebuildMenu(TrayStatus status) async {
    final items = <MenuItem>[
      MenuItem(
        key: 'show',
        label: 'Show Prysm',
        onClick: (_) => unawaited(_showWindow()),
      ),
      MenuItem.separator(),
    ];

    CallSnapshot? callSnapshot;
    try {
      callSnapshot = CallManager.instance.snapshot;
    } catch (_) {}

    final incoming = callSnapshot?.state == CallState.incoming;
    final active = callSnapshot?.state == CallState.active;
    final incomingCallId = callSnapshot?.callId;
    final incomingPeer = callSnapshot?.peerOnion;

    if (incoming && incomingCallId != null && incomingPeer != null) {
      items.addAll([
        MenuItem(label: 'Incoming call', disabled: true),
        MenuItem(
          key: 'call_accept',
          label: 'Accept call',
          onClick: (_) => unawaited(_acceptCallFromTray()),
        ),
        MenuItem(
          key: 'call_decline',
          label: 'Decline call',
          onClick: (_) => unawaited(
            CallManager.instance.declineFromNotification(
              callId: incomingCallId,
              peerOnion: incomingPeer,
            ),
          ),
        ),
        MenuItem.separator(),
      ]);
    } else if (active) {
      items.add(
        MenuItem(
          key: 'call_hangup',
          label: 'Hang up',
          onClick: (_) => unawaited(CallManager.instance.endCall()),
        ),
      );
      items.add(MenuItem.separator());
    }

    if (!Platform.isLinux) {
      final pendingLine = status.pendingCount == 1
          ? 'Pending: 1 message'
          : 'Pending: ${status.pendingCount} messages';
      final unreadLine = status.unreadTotal == 1
          ? 'Unread: 1'
          : 'Unread: ${status.unreadTotal}';
      items.addAll([
        MenuItem(
          label: 'Tor: ${_formatTorMenu(status.torLabel)}',
          disabled: true,
        ),
        if (status.inCall)
          MenuItem(label: 'In call', disabled: true),
        MenuItem(label: pendingLine, disabled: true),
        MenuItem(label: unreadLine, disabled: true),
        MenuItem.separator(),
      ]);
    } else if (status.inCall) {
      items.add(MenuItem(label: 'In call', disabled: true));
      items.add(MenuItem.separator());
    }

    items.add(
      MenuItem(
        key: 'quit',
        label: 'Quit',
        onClick: (_) => unawaited(onQuitRequested()),
      ),
    );

    await trayManager.setContextMenu(Menu(items: items));
  }

  String _formatTorMenu(String torLabel) => switch (torLabel) {
        'connected' => 'Connected',
        'connecting' => 'Connecting',
        'off' => 'Off',
        _ when torLabel.startsWith('connecting (') =>
          'Connecting ${torLabel.substring('connecting '.length)}',
        _ => torLabel,
      };

  Future<void> _showWindow() async {
    await windowManager.show();
    await windowManager.restore();
    await windowManager.focus();
  }

  Future<void> _acceptCallFromTray() async {
    await _showWindow();
    await CallManager.instance.acceptIncoming();
  }

  /// Called from tray menu Quit and shared shutdown path.
  Future<void> onQuitRequested() async {
    // Import cycle avoided: main.dart registers this callback.
    await _onQuit?.call();
  }

  Future<void> Function()? _onQuit;

  void registerQuitHandler(Future<void> Function() handler) {
    _onQuit = handler;
  }

  Future<void> destroy() async {
    if (!_isDesktop) return;
    _pollTimer?.cancel();
    _unreadDebounce?.cancel();
    await _batterySaverSub?.cancel();
    await _bootstrapSub?.cancel();
    await _torSub?.cancel();
    await _pendingSub?.cancel();
    await _refreshSub?.cancel();
    if (CallForegroundSession.onActiveChanged != null) {
      CallForegroundSession.onActiveChanged = null;
    }
    if (_callManagerListener != null) {
      try {
        CallManager.instance.removeListener(_callManagerListener!);
      } catch (_) {}
      _callManagerListener = null;
    }
    trayManager.removeListener(this);
    try {
      await trayManager.destroy();
    } catch (_) {}
    _started = false;
    _initialized = false;
  }

  @override
  void onTrayIconMouseUp() {
    unawaited(_showWindow());
  }

  @override
  void onTrayIconMouseDown() {}

  @override
  void onTrayIconRightMouseDown() {}

  @override
  void onTrayIconRightMouseUp() {}

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show':
        unawaited(_showWindow());
      case 'quit':
        unawaited(onQuitRequested());
    }
  }
}
