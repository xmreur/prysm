import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter/foundation.dart' as kIsWeb;
import 'package:flutter/material.dart';

class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  final FlutterLocalNotificationsPlugin _notificationsPlugin = FlutterLocalNotificationsPlugin();

  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    const AndroidInitializationSettings initializationSettingsAndroid = AndroidInitializationSettings('@mipmap/ic_launcher');

    const DarwinInitializationSettings initializationSettingsDarwin = DarwinInitializationSettings();
    
    const LinuxInitializationSettings initializationSettingsLinux = LinuxInitializationSettings(defaultActionName: 'Open notification');

    const WindowsInitializationSettings initializationSettingsWindows = WindowsInitializationSettings(appName: 'Prysm', appUserModelId: 'com.xmreur.prysm', guid: '02fe3791-c87d-4b3c-8549-1cf0b68cd91d');

    final InitializationSettings initializationSettings = InitializationSettings(
      android: initializationSettingsAndroid,
      iOS: initializationSettingsDarwin,
      macOS: initializationSettingsDarwin,
      linux: initializationSettingsLinux,
      windows: initializationSettingsWindows,
    );

    await _notificationsPlugin.initialize(initializationSettings, onDidReceiveNotificationResponse: onDidReceiveNotificationResponse,);
  }

  void onDidReceiveNotificationResponse(NotificationResponse details) {
    // Handle notifications tap if needed
    // For now, we're just showing notifications, not handling taps
  }

  Future<void> showNewMessageNotification({
    required String senderName,
    required String message,
    required int notificationId,
  }) async {
    if (!_initialized) await init();

    const AndroidNotificationDetails androidNotificationDetails = AndroidNotificationDetails('prysm_notification_channel', 'New Messages', channelDescription: 'Notification channel for new messages', importance: Importance.max, priority: Priority.high);

    const DarwinNotificationDetails darwinNotificationDetails = DarwinNotificationDetails();

    const LinuxNotificationDetails linuxNotificationDetails = LinuxNotificationDetails();

    const WindowsNotificationDetails windowsNotificationDetails = WindowsNotificationDetails();

    const NotificationDetails notificationDetails = NotificationDetails(
      android: androidNotificationDetails,
      iOS: darwinNotificationDetails,
      macOS: darwinNotificationDetails,
      linux: linuxNotificationDetails,
      windows: windowsNotificationDetails,
    );

    await _notificationsPlugin.show(
      notificationId,
      'New message from $senderName',
      message,
      notificationDetails
    );
  }

  Future<void> cancelNotification(int id) async {
    await _notificationsPlugin.cancel(id);
  }

  Future<void> cancelAllNotifications() async {
    await _notificationsPlugin.cancelAll();
  }
}