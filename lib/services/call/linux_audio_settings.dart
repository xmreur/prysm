import 'package:shared_preferences/shared_preferences.dart';

/// Persists the Linux call microphone device selection.
class LinuxAudioSettings {
  LinuxAudioSettings._();

  static const String _deviceKey = 'linux_audio_input_device';

  static Future<String?> getSelectedDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getString(_deviceKey);
    if (value == null || value.isEmpty) {
      return null;
    }
    return value;
  }

  static Future<void> setSelectedDeviceId(String? deviceId) async {
    final prefs = await SharedPreferences.getInstance();
    if (deviceId == null || deviceId.isEmpty) {
      await prefs.remove(_deviceKey);
      return;
    }
    await prefs.setString(_deviceKey, deviceId);
  }
}
