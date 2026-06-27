import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:prysm/services/pending_notification_route.dart';

typedef NotificationTapHandler = void Function(String? payload);

class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  static NotificationTapHandler? onNotificationTap;

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

    await _captureNotificationLaunchDetails();
  }

  Future<void> _captureNotificationLaunchDetails() async {
    if (!Platform.isAndroid && !Platform.isIOS) return;

    try {
      final launchDetails =
          await _notificationsPlugin.getNotificationAppLaunchDetails();
      if (launchDetails?.didNotificationLaunchApp == true) {
        PendingNotificationRouteStore.instance.setFromPayload(
          launchDetails?.notificationResponse?.payload,
        );
      }
    } catch (_) {
      // Some platform implementations may not support launch details.
    }
  }

  void onDidReceiveNotificationResponse(NotificationResponse details) {
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

  Future<bool?> requestPermission() async {
    if (!_initialized) await init();

    bool? granted;
    final androidImpl = notificationsPlugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    granted = await androidImpl?.requestNotificationsPermission();

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
