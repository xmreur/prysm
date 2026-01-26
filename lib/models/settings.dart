// lib/models/app_settings.dart
class Settings {
  // General
  final bool enableNotifications;
  final bool showOnlineStatus;
  final bool sendReadReceipts;

  // Network/Relay
  final bool enableRelay;
  final String? personalRelayAddress;
  final bool aggressiveRetry;

  // Privacy
  final int messageRetentionDays;

  // Theme
  final int themeMode; // 0=light, 1=dark, 2=pink, 3=cyan, 4=purple, 5=orange

  Settings({
    this.enableNotifications = true,
    this.showOnlineStatus = true,
    this.sendReadReceipts = true,
    this.enableRelay = false,
    this.personalRelayAddress,
    this.aggressiveRetry = true,
    this.messageRetentionDays = 30,
    this.themeMode = 0,
  });

  // Serialize to JSON
  Map<String, dynamic> toJson() => {
    'enableNotifications': enableNotifications,
    'showOnlineStatus': showOnlineStatus,
    'sendReadReceipts': sendReadReceipts,
    'enableRelay': enableRelay,
    'personalRelayAddress': personalRelayAddress,
    'aggressiveRetry': aggressiveRetry,
    'messageRetentionDays': messageRetentionDays,
    'themeMode': themeMode,
  };

  // Deserialize from JSON
  factory Settings.fromJson(Map<String, dynamic> json) => Settings(
    enableNotifications: json['enableNotifications'] ?? true,
    showOnlineStatus: json['showOnlineStatus'] ?? true,
    sendReadReceipts: json['sendReadReceipts'] ?? true,
    enableRelay: json['enableRelay'] ?? false,
    personalRelayAddress: json['personalRelayAddress'],
    aggressiveRetry: json['aggressiveRetry'] ?? true,
    messageRetentionDays: json['messageRetentionDays'] ?? 30,
    themeMode: json['themeMode'] ?? 0,
  );

  // Copy with modifications (immutable pattern)
  Settings copyWith({
    bool? enableNotifications,
    bool? showOnlineStatus,
    bool? sendReadReceipts,
    bool? enableRelay,
    String? personalRelayAddress,
    bool? aggressiveRetry,
    int? messageRetentionDays,
    int? themeMode,
  }) => Settings(
    enableNotifications: enableNotifications ?? this.enableNotifications,
    showOnlineStatus: showOnlineStatus ?? this.showOnlineStatus,
    sendReadReceipts: sendReadReceipts ?? this.sendReadReceipts,
    enableRelay: enableRelay ?? this.enableRelay,
    personalRelayAddress: personalRelayAddress ?? this.personalRelayAddress,
    aggressiveRetry: aggressiveRetry ?? this.aggressiveRetry,
    messageRetentionDays: messageRetentionDays ?? this.messageRetentionDays,
    themeMode: themeMode ?? this.themeMode,
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
        other.enableRelay == enableRelay &&
        other.personalRelayAddress == personalRelayAddress &&
        other.aggressiveRetry == aggressiveRetry &&
        other.messageRetentionDays == messageRetentionDays &&
        other.themeMode == themeMode;
  }

  @override
  int get hashCode {
    return enableNotifications.hashCode ^
        showOnlineStatus.hashCode ^
        sendReadReceipts.hashCode ^
        enableRelay.hashCode ^
        (personalRelayAddress?.hashCode ?? 0) ^
        aggressiveRetry.hashCode ^
        messageRetentionDays.hashCode ^
        themeMode.hashCode;
  }
}
