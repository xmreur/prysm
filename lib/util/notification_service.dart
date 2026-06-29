import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:prysm/services/pending_call_action.dart';
import 'package:prysm/services/pending_notification_route.dart';

typedef NotificationTapHandler = void Function(String? payload);
typedef CallNotificationTapHandler = void Function(PendingCallAction action);

class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  static NotificationTapHandler? onNotificationTap;
  static CallNotificationTapHandler? onCallNotificationTap;

  // Must fit in signed 32-bit (Linux notification plugin validates this).
  static const int incomingCallNotificationId = 0x0CA11001;
  static const int activeCallNotificationId = 0x0CA11002;

  static const String incomingCallChannelId = 'prysm_incoming_call_channel';
  static const String activeCallChannelId = 'prysm_active_call_channel';

  final FlutterLocalNotificationsPlugin _notificationsPlugin =
      FlutterLocalNotificationsPlugin();

  bool _initialized = false;

  FlutterLocalNotificationsPlugin get notificationsPlugin =>
      _notificationsPlugin;

  static int notificationIdFor({
    String? groupId,
    required String senderId,
  }) {
    return (groupId ?? senderId).hashCode & 0x7fffffff;
  }

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    const AndroidInitializationSettings initializationSettingsAndroid =
        AndroidInitializationSettings('icon');

    const DarwinInitializationSettings initializationSettingsDarwin =
        DarwinInitializationSettings();

    const LinuxInitializationSettings initializationSettingsLinux =
        LinuxInitializationSettings(defaultActionName: 'Open notification');

    const WindowsInitializationSettings initializationSettingsWindows =
        WindowsInitializationSettings(
      appName: 'Prysm',
      appUserModelId: 'com.xmreur.prysm',
      guid: '02fe3791-c87d-4b3c-8549-1cf0b68cd91d',
    );

    final InitializationSettings initializationSettings =
        InitializationSettings(
      android: initializationSettingsAndroid,
      iOS: initializationSettingsDarwin,
      macOS: initializationSettingsDarwin,
      linux: initializationSettingsLinux,
      windows: initializationSettingsWindows,
    );

    await _notificationsPlugin.initialize(
      initializationSettings,
      onDidReceiveNotificationResponse: onDidReceiveNotificationResponse,
    );

    await _ensureAndroidCallChannels();

    await _captureNotificationLaunchDetails();
  }

  Future<void> _ensureAndroidCallChannels() async {
    if (!Platform.isAndroid) return;
    final androidImpl = _notificationsPlugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    if (androidImpl == null) return;

    await androidImpl.createNotificationChannel(
      const AndroidNotificationChannel(
        incomingCallChannelId,
        'Incoming Calls',
        description: 'Ringing incoming voice calls',
        importance: Importance.max,
        playSound: true,
        enableVibration: true,
        audioAttributesUsage: AudioAttributesUsage.notificationRingtone,
      ),
    );
    await androidImpl.createNotificationChannel(
      const AndroidNotificationChannel(
        activeCallChannelId,
        'Active Calls',
        description: 'Ongoing voice calls',
        importance: Importance.low,
        playSound: false,
        enableVibration: false,
      ),
    );
  }

  Future<void> _captureNotificationLaunchDetails() async {
    if (!Platform.isAndroid && !Platform.isIOS) return;

    try {
      final launchDetails =
          await _notificationsPlugin.getNotificationAppLaunchDetails();
      if (launchDetails?.didNotificationLaunchApp == true) {
        final response = launchDetails?.notificationResponse;
        final call = response != null
            ? PendingCallAction.fromResponse(response)
            : PendingCallAction.fromPayload(response?.payload);
        if (call != null) {
          PendingCallActionStore.instance.set(call);
        } else {
          PendingNotificationRouteStore.instance.setFromPayload(
            response?.payload,
          );
        }
      }
    } catch (_) {
      // Some platform implementations may not support launch details.
    }
  }

  void onDidReceiveNotificationResponse(NotificationResponse details) {
    final call = PendingCallAction.fromResponse(details);
    if (call != null) {
      PendingCallActionStore.instance.set(call);
      onCallNotificationTap?.call(call);
      return;
    }
    PendingNotificationRouteStore.instance.setFromPayload(details.payload);
    onNotificationTap?.call(details.payload);
  }

  Future<void> showNewMessageNotification({
    required String title,
    required String message,
    required int notificationId,
    String? payload,
    String? androidGroupKey,
  }) async {
    if (!_initialized) await init();

    final androidNotificationDetails = AndroidNotificationDetails(
      'prysm_notification_channel',
      'New Messages',
      channelDescription: 'Notification channel for new messages',
      importance: Importance.max,
      priority: Priority.high,
      groupKey: androidGroupKey,
    );

    const DarwinNotificationDetails darwinNotificationDetails =
        DarwinNotificationDetails();

    const LinuxNotificationDetails linuxNotificationDetails =
        LinuxNotificationDetails();

    const WindowsNotificationDetails windowsNotificationDetails =
        WindowsNotificationDetails();

    final NotificationDetails notificationDetails = NotificationDetails(
      android: androidNotificationDetails,
      iOS: darwinNotificationDetails,
      macOS: darwinNotificationDetails,
      linux: linuxNotificationDetails,
      windows: windowsNotificationDetails,
    );

    await _notificationsPlugin.show(
      notificationId,
      title,
      message,
      notificationDetails,
      payload: payload,
    );
  }

  Future<void> cancelConversationNotification({
    String? groupId,
    required String senderId,
  }) async {
    await cancelNotification(
      notificationIdFor(groupId: groupId, senderId: senderId),
    );
  }

  /// Dismisses the notification only when the user can see the chat in-app.
  Future<void> cancelConversationNotificationIfForeground({
    String? groupId,
    required String senderId,
  }) async {
    if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      return;
    }
    await cancelConversationNotification(
      groupId: groupId,
      senderId: senderId,
    );
  }

  Future<void> cancelNotification(int id) async {
    await _notificationsPlugin.cancel(id);
  }

  Future<void> cancelAllNotifications() async {
    await _notificationsPlugin.cancelAll();
  }

  Future<void> showIncomingCall({
    required String peerOnion,
    required String callId,
    required String displayName,
  }) async {
    if (!_initialized) await init();

    final payload = PendingCallAction(
      action: CallNotificationAction.open,
      callId: callId,
      peerOnion: peerOnion,
    ).toPayload();

    final androidDetails = AndroidNotificationDetails(
      incomingCallChannelId,
      'Incoming Calls',
      channelDescription: 'Ringing incoming voice calls',
      importance: Importance.max,
      priority: Priority.max,
      category: AndroidNotificationCategory.call,
      fullScreenIntent: true,
      playSound: true,
      enableVibration: true,
      ticker: 'Incoming call',
      visibility: NotificationVisibility.public,
      audioAttributesUsage: AudioAttributesUsage.notificationRingtone,
      styleInformation: BigTextStyleInformation(displayName),
      actions: <AndroidNotificationAction>[
        AndroidNotificationAction(
          'accept',
          'Accept',
          showsUserInterface: true,
          cancelNotification: true,
        ),
        AndroidNotificationAction(
          'decline',
          'Decline',
          cancelNotification: true,
        ),
      ],
    );

    const darwinDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentSound: true,
      presentBanner: true,
      interruptionLevel: InterruptionLevel.timeSensitive,
    );

    const linuxDetails = LinuxNotificationDetails();

    const windowsDetails = WindowsNotificationDetails();

    await _notificationsPlugin.show(
      incomingCallNotificationId,
      'Incoming call',
      displayName,
      NotificationDetails(
        android: androidDetails,
        iOS: darwinDetails,
        macOS: darwinDetails,
        linux: linuxDetails,
        windows: windowsDetails,
      ),
      payload: payload,
    );
  }

  Future<void> showActiveCall({
    required String peerOnion,
    required String callId,
    required String displayName,
  }) async {
    if (!_initialized) await init();

    final payload = PendingCallAction(
      action: CallNotificationAction.open,
      callId: callId,
      peerOnion: peerOnion,
    ).toPayload();

    final androidDetails = AndroidNotificationDetails(
      activeCallChannelId,
      'Active Calls',
      channelDescription: 'Ongoing voice calls',
      importance: Importance.low,
      priority: Priority.low,
      category: AndroidNotificationCategory.call,
      ongoing: true,
      playSound: false,
      enableVibration: false,
      actions: <AndroidNotificationAction>[
        AndroidNotificationAction(
          'hangup',
          'Hang up',
          cancelNotification: true,
        ),
      ],
    );

    const darwinDetails = DarwinNotificationDetails();
    const linuxDetails = LinuxNotificationDetails();
    const windowsDetails = WindowsNotificationDetails();

    await _notificationsPlugin.show(
      activeCallNotificationId,
      'In call',
      displayName,
      NotificationDetails(
        android: androidDetails,
        iOS: darwinDetails,
        macOS: darwinDetails,
        linux: linuxDetails,
        windows: windowsDetails,
      ),
      payload: payload,
    );
  }

  Future<void> cancelIncomingCallNotification() async {
    await cancelNotification(incomingCallNotificationId);
  }

  Future<void> cancelActiveCallNotification() async {
    await cancelNotification(activeCallNotificationId);
  }

  Future<void> cancelCallNotifications() async {
    await cancelIncomingCallNotification();
    await cancelActiveCallNotification();
  }

  Future<bool?> requestPermission() async {
    if (!_initialized) await init();

    bool? granted;
    final androidImpl = notificationsPlugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    granted = await androidImpl?.requestNotificationsPermission();
    await androidImpl?.requestFullScreenIntentPermission();

    final iosImpl = notificationsPlugin
        .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin>();
    final iosGranted = await iosImpl?.requestPermissions(
      alert: true,
      badge: true,
      sound: true,
    );
    if (iosGranted != null) {
      granted = iosGranted;
    }

    final macImpl = notificationsPlugin
        .resolvePlatformSpecificImplementation<
            MacOSFlutterLocalNotificationsPlugin>();
    final macGranted = await macImpl?.requestPermissions(
      alert: true,
      badge: true,
      sound: true,
    );
    if (macGranted != null) {
      granted = macGranted;
    }

    return granted;
  }
}
