// lib/models/app_settings.dart
import 'package:prysm/models/appearance_settings.dart';
import 'package:prysm/models/panic_action.dart';
import 'package:prysm/models/unlock_type.dart';

class Settings {
  // General
  final bool enableNotifications;
  final bool showOnlineStatus;
  final bool sendReadReceipts;
  final bool enableTypingIndicators;
  final bool minimizeToTray;
  final bool minimizeOnMinimizeButton;
  final bool enableBatterySaving;

  // Network/Relay
  final bool enableRelay;
  final String? personalRelayAddress;
  final bool aggressiveRetry;

  // Privacy
  final int messageRetentionDays;
  final PanicAction panicAction;

  // Theme
  final int themeMode; // 0=light, 1=dark, 2=pink, 3=cyan, 4=purple, 5=orange
  final AppearanceSettings appearance;

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

  // Unlock
  final UnlockType unlockType;
  final bool biometricsEnabled;

  Settings({
    this.enableNotifications = true,
    this.showOnlineStatus = true,
    this.sendReadReceipts = true,
    this.enableTypingIndicators = true,
    this.minimizeToTray = true,
    this.minimizeOnMinimizeButton = false,
    this.enableBatterySaving = false,
    this.enableRelay = false,
    this.personalRelayAddress,
    this.aggressiveRetry = true,
    this.messageRetentionDays = 30,
    this.panicAction = PanicAction.decoy,
    this.themeMode = 0,
    this.appearance = const AppearanceSettings(),
    this.avatar,
    this.username,
    this.enableFilePreview = false,
    this.enableLinkUnfurling = false,
    this.enableVoiceTranscription = false,
    this.customDownloadPath,
    this.onboardingCompleted = false,
    this.unlockType = UnlockType.pin,
    this.biometricsEnabled = false,
  });

  // Serialize to JSON
  Map<String, dynamic> toJson() => {
    'enableNotifications': enableNotifications,
    'showOnlineStatus': showOnlineStatus,
    'sendReadReceipts': sendReadReceipts,
    'enableTypingIndicators': enableTypingIndicators,
    'minimizeToTray': minimizeToTray,
    'minimizeOnMinimizeButton': minimizeOnMinimizeButton,
    'enableBatterySaving': enableBatterySaving,
    'enableRelay': enableRelay,
    'personalRelayAddress': personalRelayAddress,
    'aggressiveRetry': aggressiveRetry,
    'messageRetentionDays': messageRetentionDays,
    'panicAction': panicAction.name,
    'themeMode': themeMode,
    'appearance': appearance.toJson(),
    'avatar': avatar,
    'username': username,
    'enableFilePreview': enableFilePreview,
    'enableLinkUnfurling': enableLinkUnfurling,
    'enableVoiceTranscription': enableVoiceTranscription,
    'customDownloadPath': customDownloadPath,
    'onboardingCompleted': onboardingCompleted,
    'unlockType': unlockType.toJson(),
    'biometricsEnabled': biometricsEnabled,
  };

  // Deserialize from JSON
  factory Settings.fromJson(Map<String, dynamic> json) => Settings(
    enableNotifications: json['enableNotifications'] ?? true,
    showOnlineStatus: json['showOnlineStatus'] ?? true,
    sendReadReceipts: json['sendReadReceipts'] ?? true,
    enableTypingIndicators: json['enableTypingIndicators'] ?? true,
    minimizeToTray: json['minimizeToTray'] ?? true,
    minimizeOnMinimizeButton: json['minimizeOnMinimizeButton'] ?? false,
    enableBatterySaving: json['enableBatterySaving'] ?? false,
    enableRelay: json['enableRelay'] ?? false,
    personalRelayAddress: json['personalRelayAddress'],
    aggressiveRetry: json['aggressiveRetry'] ?? true,
    messageRetentionDays: json['messageRetentionDays'] ?? 30,
    panicAction: PanicAction.fromJson(json['panicAction'] as String?),
    themeMode: json['themeMode'] ?? 0,
    appearance: AppearanceSettings.fromJson(
      json['appearance'] as Map<String, dynamic>?,
    ),
    avatar: json['avatar'],
    username: json['username'],
    enableFilePreview: json['enableFilePreview'] ?? false,
    enableLinkUnfurling: json['enableLinkUnfurling'] ?? false,
    enableVoiceTranscription: json['enableVoiceTranscription'] ?? false,
    customDownloadPath: json['customDownloadPath'],
    onboardingCompleted: json['onboardingCompleted'] ?? false,
    unlockType: json.containsKey('unlockType')
        ? UnlockType.fromJson(json['unlockType'] as String?)
        : UnlockType.pin,
    biometricsEnabled: json['biometricsEnabled'] ?? false,
  );

  // Copy with modifications (immutable pattern)
  Settings copyWith({
    bool? enableNotifications,
    bool? showOnlineStatus,
    bool? sendReadReceipts,
    bool? enableTypingIndicators,
    bool? minimizeToTray,
    bool? minimizeOnMinimizeButton,
    bool? enableBatterySaving,
    bool? enableRelay,
    String? personalRelayAddress,
    bool? aggressiveRetry,
    int? messageRetentionDays,
    PanicAction? panicAction,
    int? themeMode,
    AppearanceSettings? appearance,
    String? avatar,
    String? username,
    bool? enableFilePreview,
    bool? enableLinkUnfurling,
    bool? enableVoiceTranscription,
    String? customDownloadPath,
    bool? onboardingCompleted,
    UnlockType? unlockType,
    bool? biometricsEnabled,
    bool clearCustomDownloadPath = false,
  }) => Settings(
    enableNotifications: enableNotifications ?? this.enableNotifications,
    showOnlineStatus: showOnlineStatus ?? this.showOnlineStatus,
    sendReadReceipts: sendReadReceipts ?? this.sendReadReceipts,
    enableTypingIndicators:
        enableTypingIndicators ?? this.enableTypingIndicators,
    minimizeToTray: minimizeToTray ?? this.minimizeToTray,
    minimizeOnMinimizeButton:
        minimizeOnMinimizeButton ?? this.minimizeOnMinimizeButton,
    enableBatterySaving: enableBatterySaving ?? this.enableBatterySaving,
    enableRelay: enableRelay ?? this.enableRelay,
    personalRelayAddress: personalRelayAddress ?? this.personalRelayAddress,
    aggressiveRetry: aggressiveRetry ?? this.aggressiveRetry,
    messageRetentionDays: messageRetentionDays ?? this.messageRetentionDays,
    panicAction: panicAction ?? this.panicAction,
    themeMode: themeMode ?? this.themeMode,
    appearance: appearance ?? this.appearance,
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
    unlockType: unlockType ?? this.unlockType,
    biometricsEnabled: biometricsEnabled ?? this.biometricsEnabled,
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
        other.enableTypingIndicators == enableTypingIndicators &&
        other.minimizeToTray == minimizeToTray &&
        other.minimizeOnMinimizeButton == minimizeOnMinimizeButton &&
        other.enableBatterySaving == enableBatterySaving &&
        other.enableRelay == enableRelay &&
        other.personalRelayAddress == personalRelayAddress &&
        other.aggressiveRetry == aggressiveRetry &&
        other.messageRetentionDays == messageRetentionDays &&
        other.panicAction == panicAction &&
        other.themeMode == themeMode &&
        other.appearance == appearance &&
        other.avatar == avatar &&
        other.username == username &&
        other.enableFilePreview == enableFilePreview &&
        other.enableLinkUnfurling == enableLinkUnfurling &&
        other.enableVoiceTranscription == enableVoiceTranscription &&
        other.customDownloadPath == customDownloadPath &&
        other.onboardingCompleted == onboardingCompleted &&
        other.unlockType == unlockType &&
        other.biometricsEnabled == biometricsEnabled;
  }

  @override
  int get hashCode {
    return enableNotifications.hashCode ^
        showOnlineStatus.hashCode ^
        sendReadReceipts.hashCode ^
        enableTypingIndicators.hashCode ^
        minimizeToTray.hashCode ^
        minimizeOnMinimizeButton.hashCode ^
        enableBatterySaving.hashCode ^
        enableRelay.hashCode ^
        (personalRelayAddress?.hashCode ?? 0) ^
        aggressiveRetry.hashCode ^
        messageRetentionDays.hashCode ^
        panicAction.hashCode ^
        themeMode.hashCode ^
        appearance.hashCode ^
        (avatar?.hashCode ?? 0) ^
        (username?.hashCode ?? 0) ^
        enableFilePreview.hashCode ^
        enableLinkUnfurling.hashCode ^
        enableVoiceTranscription.hashCode ^
        (customDownloadPath?.hashCode ?? 0) ^
        onboardingCompleted.hashCode ^
        unlockType.hashCode ^
        biometricsEnabled.hashCode;
  }
}
