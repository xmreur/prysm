// lib/services/settings_service.dart
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:prysm/models/settings.dart';

class SettingsService {
  static const String appVersion = 'v0.0.9';
  static const String appName = 'Prysm';
  static const String appDescription = 'Privacy-focused P2P messaging';

  String get version => appVersion;
  String get name => appName;
  String get description => appDescription;

  // Singleton pattern
  static final SettingsService _instance = SettingsService._internal();
  factory SettingsService() => _instance;
  SettingsService._internal();

  static const String _settingsKey = 'app_settings';

  Settings _settings = Settings();
  SharedPreferences? _prefs;

  // Getters for easy access
  Settings get settings => _settings;

  // General
  bool get enableNotifications => _settings.enableNotifications;
  bool get showOnlineStatus => _settings.showOnlineStatus;
  bool get sendReadReceipts => _settings.sendReadReceipts;

  // Network/Relay
  bool get enableRelay => _settings.enableRelay;
  String? get personalRelayAddress => _settings.personalRelayAddress;
  bool get aggressiveRetry => _settings.aggressiveRetry;

  // Privacy
  int get messageRetentionDays => _settings.messageRetentionDays;

  // Theme
  int get themeMode => _settings.themeMode;

  // Initialize (call at app startup)
  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    await load();
  }

  // Load settings from storage
  Future<void> load() async {
    final String? jsonString = _prefs?.getString(_settingsKey);
    if (jsonString != null) {
      try {
        _settings = Settings.fromJson(jsonDecode(jsonString));
      } catch (e) {
        print('Error loading settings: $e');
        _settings = Settings(); // Use defaults
      }
    } else {
      _settings = Settings(); // First time - use defaults
    }
  }

  // Save settings to storage
  Future<void> save() async {
    try {
      final jsonString = jsonEncode(_settings.toJson());
      await _prefs?.setString(_settingsKey, jsonString);
    } catch (e) {
      print('Error saving settings: $e');
    }
  }

  // ==================== UPDATE METHODS ====================

  // General Settings
  Future<void> setEnableNotifications(bool value) async {
    _settings = _settings.copyWith(enableNotifications: value);
    await save();
  }

  Future<void> setShowOnlineStatus(bool value) async {
    _settings = _settings.copyWith(showOnlineStatus: value);
    await save();
  }

  Future<void> setSendReadReceipts(bool value) async {
    _settings = _settings.copyWith(sendReadReceipts: value);
    await save();
  }

  // Network/Relay Settings
  Future<void> setEnableRelay(bool value) async {
    _settings = _settings.copyWith(enableRelay: value);
    await save();
  }

  Future<void> setPersonalRelayAddress(String? value) async {
    _settings = _settings.copyWith(personalRelayAddress: value);
    await save();
  }

  Future<void> setAggressiveRetry(bool value) async {
    _settings = _settings.copyWith(aggressiveRetry: value);
    await save();
  }

  // Privacy Settings
  Future<void> setMessageRetentionDays(int value) async {
    _settings = _settings.copyWith(messageRetentionDays: value);
    await save();
  }

  // Theme Settings
  Future<void> setThemeMode(int value) async {
    _settings = _settings.copyWith(themeMode: value);
    await save();
  }

  // ==================== BULK OPERATIONS ====================

  // Update multiple settings at once
  Future<void> updateSettings(Settings newSettings) async {
    _settings = newSettings;
    await save();
  }

  // Reset all settings to defaults
  Future<void> reset() async {
    _settings = Settings();
    await save();
  }

  // ==================== UTILITY METHODS ====================

  // Check if settings are initialized
  bool get isInitialized => _prefs != null;

  // Export settings as JSON string (for backup)
  String exportSettings() {
    return jsonEncode(_settings.toJson());
  }

  // Import settings from JSON string (for restore)
  Future<bool> importSettings(String jsonString) async {
    try {
      final settings = Settings.fromJson(jsonDecode(jsonString));
      await updateSettings(settings);
      return true;
    } catch (e) {
      print('Error importing settings: $e');
      return false;
    }
  }

  // Clear all settings (for debugging)
  Future<void> clear() async {
    await _prefs?.remove(_settingsKey);
    _settings = Settings();
  }

  // Print current settings (for debugging)
  void printSettings() {
    print('=== Current Settings ===');
    print('Notifications: ${_settings.enableNotifications}');
    print('Online Status: ${_settings.showOnlineStatus}');
    print('Read Receipts: ${_settings.sendReadReceipts}');
    print('Enable Relay: ${_settings.enableRelay}');
    print('Relay Address: ${_settings.personalRelayAddress ?? "Not set"}');
    print('Aggressive Retry: ${_settings.aggressiveRetry}');
    print('Message Retention: ${_settings.messageRetentionDays} days');
    print('Theme Mode: ${_getThemeModeName(_settings.themeMode)}');
    print('=======================');
  }

  String _getThemeModeName(int mode) {
    switch (mode) {
      case 0:
        return 'Light';
      case 1:
        return 'Dark';
      case 2:
        return 'Pink';
      case 3:
        return 'Cyan';
      case 4:
        return 'Purple';
      case 5:
        return 'Orange';
      default:
        return 'Unknown';
    }
  }
}
