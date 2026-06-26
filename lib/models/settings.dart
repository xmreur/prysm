// lib/models/app_settings.dart
import 'package:prysm/models/panic_action.dart';

class Settings {
  // General
  final bool enableNotifications;
  final bool showOnlineStatus;
  final bool sendReadReceipts;
  final bool minimizeToTray;
  final bool minimizeOnMinimizeButton;
  final bool enableBatterySaving;

  // Network/Relay
  final bool enableRelay;
  final String? personalRelayAddress;
  final bool aggressiveRetry;
  final bool enableWebSocketTransport;

  // Privacy
  final int messageRetentionDays;
  final PanicAction panicAction;

  // Theme
  final int themeMode; // 0=light, 1=dark, 2=pink, 3=cyan, 4=purple, 5=orange

  // Profile
  final String? avatar; // base64 encoded avatar image
  final String? username; // display name

  // Files
  final bool enableFilePreview;
  final bool enableLinkUnfurling;
  final bool enableVoiceTranscription;
  final String? customDownloadPath;

  // Onboarding
  final bool onboardingCompleted;

  Settings({
    this.enableNotifications = true,
    this.showOnlineStatus = true,
    this.sendReadReceipts = true,
    this.minimizeToTray = true,
    this.minimizeOnMinimizeButton = false,
    this.enableBatterySaving = false,
    this.enableRelay = false,
    this.personalRelayAddress,
    this.aggressiveRetry = true,
    this.enableWebSocketTransport = false,
    this.messageRetentionDays = 30,
    this.panicAction = PanicAction.decoy,
    this.themeMode = 0,
    this.avatar,
    this.username,
    this.enableFilePreview = false,
    this.enableLinkUnfurling = false,
    this.enableVoiceTranscription = false,
    this.customDownloadPath,
    this.onboardingCompleted = false,
  });

  // Serialize to JSON
  Map<String, dynamic> toJson() => {
    'enableNotifications': enableNotifications,
    'showOnlineStatus': showOnlineStatus,
    'sendReadReceipts': sendReadReceipts,
    'minimizeToTray': minimizeToTray,
    'minimizeOnMinimizeButton': minimizeOnMinimizeButton,
    'enableBatterySaving': enableBatterySaving,
    'enableRelay': enableRelay,
    'personalRelayAddress': personalRelayAddress,
    'aggressiveRetry': aggressiveRetry,
    'enableWebSocketTransport': enableWebSocketTransport,
    'messageRetentionDays': messageRetentionDays,
    'panicAction': panicAction.name,
    'themeMode': themeMode,
    'avatar': avatar,
    'username': username,
    'enableFilePreview': enableFilePreview,
    'enableLinkUnfurling': enableLinkUnfurling,
    'enableVoiceTranscription': enableVoiceTranscription,
    'customDownloadPath': customDownloadPath,
    'onboardingCompleted': onboardingCompleted,
  };

  // Deserialize from JSON
  factory Settings.fromJson(Map<String, dynamic> json) => Settings(
    enableNotifications: json['enableNotifications'] ?? true,
    showOnlineStatus: json['showOnlineStatus'] ?? true,
    sendReadReceipts: json['sendReadReceipts'] ?? true,
    minimizeToTray: json['minimizeToTray'] ?? true,
    minimizeOnMinimizeButton: json['minimizeOnMinimizeButton'] ?? false,
    enableBatterySaving: json['enableBatterySaving'] ?? false,
    enableRelay: json['enableRelay'] ?? false,
    personalRelayAddress: json['personalRelayAddress'],
    aggressiveRetry: json['aggressiveRetry'] ?? true,
    enableWebSocketTransport: json['enableWebSocketTransport'] ?? false,
    messageRetentionDays: json['messageRetentionDays'] ?? 30,
    panicAction: PanicAction.fromJson(json['panicAction'] as String?),
    themeMode: json['themeMode'] ?? 0,
    avatar: json['avatar'],
    username: json['username'],
    enableFilePreview: json['enableFilePreview'] ?? false,
    enableLinkUnfurling: json['enableLinkUnfurling'] ?? false,
    enableVoiceTranscription: json['enableVoiceTranscription'] ?? false,
    customDownloadPath: json['customDownloadPath'],
    onboardingCompleted: json['onboardingCompleted'] ?? false,
  );

  // Copy with modifications (immutable pattern)
  Settings copyWith({
    bool? enableNotifications,
    bool? showOnlineStatus,
    bool? sendReadReceipts,
    bool? minimizeToTray,
    bool? minimizeOnMinimizeButton,
    bool? enableBatterySaving,
    bool? enableRelay,
    String? personalRelayAddress,
    bool? aggressiveRetry,
    bool? enableWebSocketTransport,
    int? messageRetentionDays,
    PanicAction? panicAction,
    int? themeMode,
    String? avatar,
    String? username,
    bool? enableFilePreview,
    bool? enableLinkUnfurling,
    bool? enableVoiceTranscription,
    String? customDownloadPath,
    bool? onboardingCompleted,
    bool clearCustomDownloadPath = false,
  }) => Settings(
    enableNotifications: enableNotifications ?? this.enableNotifications,
    showOnlineStatus: showOnlineStatus ?? this.showOnlineStatus,
    sendReadReceipts: sendReadReceipts ?? this.sendReadReceipts,
    minimizeToTray: minimizeToTray ?? this.minimizeToTray,
    minimizeOnMinimizeButton:
        minimizeOnMinimizeButton ?? this.minimizeOnMinimizeButton,
    enableBatterySaving: enableBatterySaving ?? this.enableBatterySaving,
    enableRelay: enableRelay ?? this.enableRelay,
    personalRelayAddress: personalRelayAddress ?? this.personalRelayAddress,
    aggressiveRetry: aggressiveRetry ?? this.aggressiveRetry,
    enableWebSocketTransport:
        enableWebSocketTransport ?? this.enableWebSocketTransport,
    messageRetentionDays: messageRetentionDays ?? this.messageRetentionDays,
    panicAction: panicAction ?? this.panicAction,
    themeMode: themeMode ?? this.themeMode,
    avatar: avatar ?? this.avatar,
    username: username ?? this.username,
    enableFilePreview: enableFilePreview ?? this.enableFilePreview,
    enableLinkUnfurling: enableLinkUnfurling ?? this.enableLinkUnfurling,
    enableVoiceTranscription:
        enableVoiceTranscription ?? this.enableVoiceTranscription,
    customDownloadPath: clearCustomDownloadPath
        ? null
        : (customDownloadPath ?? this.customDownloadPath),
    onboardingCompleted: onboardingCompleted ?? this.onboardingCompleted,
  );

  @override
  String toString() {
    return 'Settings('
        'notifications: $enableNotifications, '
        'onlineStatus: $showOnlineStatus, '
        'readReceipts: $sendReadReceipts, '
        'relay: $enableRelay, '
        'theme: $themeMode'
        ')';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;

    return other is Settings &&
        other.enableNotifications == enableNotifications &&
        other.showOnlineStatus == showOnlineStatus &&
        other.sendReadReceipts == sendReadReceipts &&
        other.minimizeToTray == minimizeToTray &&
        other.minimizeOnMinimizeButton == minimizeOnMinimizeButton &&
        other.enableBatterySaving == enableBatterySaving &&
        other.enableRelay == enableRelay &&
        other.personalRelayAddress == personalRelayAddress &&
        other.aggressiveRetry == aggressiveRetry &&
        other.enableWebSocketTransport == enableWebSocketTransport &&
        other.messageRetentionDays == messageRetentionDays &&
        other.panicAction == panicAction &&
        other.themeMode == themeMode &&
        other.avatar == avatar &&
        other.username == username &&
        other.enableFilePreview == enableFilePreview &&
        other.enableLinkUnfurling == enableLinkUnfurling &&
        other.enableVoiceTranscription == enableVoiceTranscription &&
        other.customDownloadPath == customDownloadPath &&
        other.onboardingCompleted == onboardingCompleted;
  }

  @override
  int get hashCode {
    return enableNotifications.hashCode ^
        showOnlineStatus.hashCode ^
        sendReadReceipts.hashCode ^
        minimizeToTray.hashCode ^
        minimizeOnMinimizeButton.hashCode ^
        enableBatterySaving.hashCode ^
        enableRelay.hashCode ^
        (personalRelayAddress?.hashCode ?? 0) ^
        aggressiveRetry.hashCode ^
        enableWebSocketTransport.hashCode ^
        messageRetentionDays.hashCode ^
        panicAction.hashCode ^
        themeMode.hashCode ^
        (avatar?.hashCode ?? 0) ^
        (username?.hashCode ?? 0) ^
        enableFilePreview.hashCode ^
        enableLinkUnfurling.hashCode ^
        enableVoiceTranscription.hashCode ^
        (customDownloadPath?.hashCode ?? 0) ^
        onboardingCompleted.hashCode;
  }
}
