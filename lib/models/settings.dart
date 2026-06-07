// lib/models/app_settings.dart
class Settings {
  // General
  final bool enableNotifications;
  final bool showOnlineStatus;
  final bool sendReadReceipts;
  final bool minimizeToTray;
  final bool minimizeOnMinimizeButton;

  // Network/Relay
  final bool enableRelay;
  final String? personalRelayAddress;
  final bool aggressiveRetry;

  // Privacy
  final int messageRetentionDays;

  // Theme
  final int themeMode; // 0=light, 1=dark, 2=pink, 3=cyan, 4=purple, 5=orange

  // Profile
  final String? avatar; // base64 encoded avatar image
  final String? username; // display name

  // Files
  final bool enableFilePreview;
  final String? customDownloadPath;

  Settings({
    this.enableNotifications = true,
    this.showOnlineStatus = true,
    this.sendReadReceipts = true,
    this.minimizeToTray = true,
    this.minimizeOnMinimizeButton = false,
    this.enableRelay = false,
    this.personalRelayAddress,
    this.aggressiveRetry = true,
    this.messageRetentionDays = 30,
    this.themeMode = 0,
    this.avatar,
    this.username,
    this.enableFilePreview = false,
    this.customDownloadPath,
  });

  // Serialize to JSON
  Map<String, dynamic> toJson() => {
    'enableNotifications': enableNotifications,
    'showOnlineStatus': showOnlineStatus,
    'sendReadReceipts': sendReadReceipts,
    'minimizeToTray': minimizeToTray,
    'minimizeOnMinimizeButton': minimizeOnMinimizeButton,
    'enableRelay': enableRelay,
    'personalRelayAddress': personalRelayAddress,
    'aggressiveRetry': aggressiveRetry,
    'messageRetentionDays': messageRetentionDays,
    'themeMode': themeMode,
    'avatar': avatar,
    'username': username,
    'enableFilePreview': enableFilePreview,
    'customDownloadPath': customDownloadPath,
  };

  // Deserialize from JSON
  factory Settings.fromJson(Map<String, dynamic> json) => Settings(
    enableNotifications: json['enableNotifications'] ?? true,
    showOnlineStatus: json['showOnlineStatus'] ?? true,
    sendReadReceipts: json['sendReadReceipts'] ?? true,
    minimizeToTray: json['minimizeToTray'] ?? true,
    minimizeOnMinimizeButton: json['minimizeOnMinimizeButton'] ?? false,
    enableRelay: json['enableRelay'] ?? false,
    personalRelayAddress: json['personalRelayAddress'],
    aggressiveRetry: json['aggressiveRetry'] ?? true,
    messageRetentionDays: json['messageRetentionDays'] ?? 30,
    themeMode: json['themeMode'] ?? 0,
    avatar: json['avatar'],
    username: json['username'],
    enableFilePreview: json['enableFilePreview'] ?? false,
    customDownloadPath: json['customDownloadPath'],
  );

  // Copy with modifications (immutable pattern)
  Settings copyWith({
    bool? enableNotifications,
    bool? showOnlineStatus,
    bool? sendReadReceipts,
    bool? minimizeToTray,
    bool? minimizeOnMinimizeButton,
    bool? enableRelay,
    String? personalRelayAddress,
    bool? aggressiveRetry,
    int? messageRetentionDays,
    int? themeMode,
    String? avatar,
    String? username,
    bool? enableFilePreview,
    String? customDownloadPath,
    bool clearCustomDownloadPath = false,
  }) => Settings(
    enableNotifications: enableNotifications ?? this.enableNotifications,
    showOnlineStatus: showOnlineStatus ?? this.showOnlineStatus,
    sendReadReceipts: sendReadReceipts ?? this.sendReadReceipts,
    minimizeToTray: minimizeToTray ?? this.minimizeToTray,
    minimizeOnMinimizeButton:
        minimizeOnMinimizeButton ?? this.minimizeOnMinimizeButton,
    enableRelay: enableRelay ?? this.enableRelay,
    personalRelayAddress: personalRelayAddress ?? this.personalRelayAddress,
    aggressiveRetry: aggressiveRetry ?? this.aggressiveRetry,
    messageRetentionDays: messageRetentionDays ?? this.messageRetentionDays,
    themeMode: themeMode ?? this.themeMode,
    avatar: avatar ?? this.avatar,
    username: username ?? this.username,
    enableFilePreview: enableFilePreview ?? this.enableFilePreview,
    customDownloadPath: clearCustomDownloadPath
        ? null
        : (customDownloadPath ?? this.customDownloadPath),
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
        other.enableRelay == enableRelay &&
        other.personalRelayAddress == personalRelayAddress &&
        other.aggressiveRetry == aggressiveRetry &&
        other.messageRetentionDays == messageRetentionDays &&
        other.themeMode == themeMode &&
        other.avatar == avatar &&
        other.username == username &&
        other.enableFilePreview == enableFilePreview &&
        other.customDownloadPath == customDownloadPath;
  }

  @override
  int get hashCode {
    return enableNotifications.hashCode ^
        showOnlineStatus.hashCode ^
        sendReadReceipts.hashCode ^
        minimizeToTray.hashCode ^
        minimizeOnMinimizeButton.hashCode ^
        enableRelay.hashCode ^
        (personalRelayAddress?.hashCode ?? 0) ^
        aggressiveRetry.hashCode ^
        messageRetentionDays.hashCode ^
        themeMode.hashCode ^
        (avatar?.hashCode ?? 0) ^
        (username?.hashCode ?? 0) ^
        enableFilePreview.hashCode ^
        (customDownloadPath?.hashCode ?? 0);
  }
}
