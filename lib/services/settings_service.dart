// lib/services/settings_service.dart
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:prysm/crypto/key_store.dart';
import 'package:prysm/models/panic_action.dart';
import 'package:prysm/models/settings.dart';
import 'package:prysm/models/unlock_type.dart';
import 'package:prysm/services/link_unfurl_service.dart';

class SettingsService {
  static const String appVersion = 'v0.2.0';
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
  bool _settingsExistedAtLaunch = false;

  // Getters for easy access
  Settings get settings => _settings;

  // General
  bool get enableNotifications => _settings.enableNotifications;
  bool get showOnlineStatus => _settings.showOnlineStatus;
  bool get sendReadReceipts => _settings.sendReadReceipts;
  bool get enableTypingIndicators => _settings.enableTypingIndicators;
  bool get minimizeToTray => _settings.minimizeToTray;
  bool get minimizeOnMinimizeButton => _settings.minimizeOnMinimizeButton;
  bool get enableBatterySaving => _settings.enableBatterySaving;

  // Network/Relay
  bool get enableRelay => _settings.enableRelay;
  String? get personalRelayAddress => _settings.personalRelayAddress;
  bool get aggressiveRetry => _settings.aggressiveRetry;

  // Privacy
  int get messageRetentionDays => _settings.messageRetentionDays;
  PanicAction get panicAction => _settings.panicAction;

  // Theme
  int get themeMode => _settings.themeMode;

  // Profile
  String? get avatar => _settings.avatar;
  String? get username => _settings.username;

  // Files
  bool get enableFilePreview => _settings.enableFilePreview;
  bool get enableLinkUnfurling => _settings.enableLinkUnfurling;
  bool get enableVoiceTranscription => _settings.enableVoiceTranscription;
  String? get customDownloadPath => _settings.customDownloadPath;

  // Onboarding
  bool get onboardingCompleted => _settings.onboardingCompleted;

  UnlockType get unlockType => _settings.unlockType;

  static const String _legacyReadReceiptsKey = 'read_receipts';

  // Initialize (call at app startup)
  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    _settingsExistedAtLaunch = _prefs?.getString(_settingsKey) != null;
    await load();
    await _migrateLegacyPrefs();
    await migrateUnlockTypeForExistingKeys();
  }

  /// Existing installs without unlockType default to passphrase (12+ char era).
  Future<void> migrateUnlockTypeForExistingKeys() async {
    final raw = _prefs?.getString(_settingsKey);
    if (raw == null) return;
    final json = jsonDecode(raw) as Map<String, dynamic>;
    if (json.containsKey('unlockType')) return;
    if (!await CryptoKeyStore.isPassphraseSet()) return;
    await setUnlockType(UnlockType.passphrase);
  }

  /// One-time migration from privacy screen SharedPreferences keys.
  Future<void> _migrateLegacyPrefs() async {
    if (_prefs == null) return;
    if (_prefs!.containsKey(_legacyReadReceiptsKey)) {
      final legacy = _prefs!.getBool(_legacyReadReceiptsKey) ?? true;
      await setSendReadReceipts(legacy);
      await _prefs!.remove(_legacyReadReceiptsKey);
    }
  }

  /// Skips onboarding for upgrades: settings existed before this launch and
  /// the user already has keys or contacts from a prior session.
  Future<void> migrateOnboardingIfExisting({
    required Future<String?> Function() readPublicKey,
    required int contactCount,
  }) async {
    if (_settings.onboardingCompleted || !_settingsExistedAtLaunch) return;

    final publicKey = await readPublicKey();
    if (publicKey != null || contactCount > 0) {
      await setOnboardingCompleted(true);
    }
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

  Future<void> setEnableTypingIndicators(bool value) async {
    _settings = _settings.copyWith(enableTypingIndicators: value);
    await save();
  }

  Future<void> setMinimizeToTray(bool value) async {
    _settings = _settings.copyWith(minimizeToTray: value);
    await save();
  }

  Future<void> setMinimizeOnMinimizeButton(bool value) async {
    _settings = _settings.copyWith(minimizeOnMinimizeButton: value);
    await save();
  }

  Future<void> setEnableBatterySaving(bool value) async {
    _settings = _settings.copyWith(enableBatterySaving: value);
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

  Future<void> setPanicAction(PanicAction value) async {
    _settings = _settings.copyWith(panicAction: value);
    await save();
  }

  // Theme Settings
  Future<void> setThemeMode(int value) async {
    _settings = _settings.copyWith(themeMode: value);
    await save();
  }

  // Profile Settings
  Future<void> setAvatar(String? value) async {
    _settings = _settings.copyWith(avatar: value);
    await save();
  }

  Future<void> setUsername(String? value) async {
    _settings = _settings.copyWith(username: value);
    await save();
  }

  Future<void> setEnableFilePreview(bool value) async {
    _settings = _settings.copyWith(enableFilePreview: value);
    await save();
  }

  Future<void> setEnableLinkUnfurling(bool value) async {
    _settings = _settings.copyWith(enableLinkUnfurling: value);
    if (!value) {
      LinkUnfurlService.instance.clearCache();
    }
    await save();
  }

  Future<void> setEnableVoiceTranscription(bool value) async {
    _settings = _settings.copyWith(enableVoiceTranscription: value);
    await save();
  }

  Future<void> setCustomDownloadPath(String path) async {
    _settings = _settings.copyWith(customDownloadPath: path);
    await save();
  }

  Future<void> clearCustomDownloadPath() async {
    _settings = _settings.copyWith(clearCustomDownloadPath: true);
    await save();
  }

  Future<void> setOnboardingCompleted(bool value) async {
    _settings = _settings.copyWith(onboardingCompleted: value);
    await save();
  }

  Future<void> setUnlockType(UnlockType value) async {
    _settings = _settings.copyWith(unlockType: value);
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
