import 'package:flutter/services.dart';

/// A PulseAudio/PipeWire input source exposed to Prysm.
class LinuxAudioDevice {
  const LinuxAudioDevice({
    required this.id,
    required this.name,
    required this.isDefault,
  });

  final String id;
  final String name;
  final bool isDefault;

  factory LinuxAudioDevice.fromMap(Map<dynamic, dynamic> map) {
    return LinuxAudioDevice(
      id: map['id'] as String? ?? '',
      name: map['name'] as String? ?? '',
      isDefault: map['isDefault'] as bool? ?? false,
    );
  }
}

/// Linux audio device enumeration for Prysm settings.
class PrysmLinuxAudio {
  PrysmLinuxAudio._();

  static const MethodChannel _methodChannel =
      MethodChannel('prysm_linux_audio');

  static Future<List<LinuxAudioDevice>> listInputDevices() async {
    final result = await _methodChannel.invokeMethod<List<dynamic>>(
      'listInputDevices',
    );
    if (result == null) return const [];
    return result
        .whereType<Map>()
        .map((entry) => LinuxAudioDevice.fromMap(entry))
        .where((device) => device.id.isNotEmpty)
        .toList(growable: false);
  }
}
