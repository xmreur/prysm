import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prysm_linux_audio/prysm_linux_audio.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const methodChannel = MethodChannel('prysm_linux_audio');

  test('listInputDevices parses native response', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, (call) async {
      if (call.method == 'listInputDevices') {
        return [
          {
            'id': 'alsa_input.test',
            'name': 'Test Mic',
            'isDefault': true,
          },
        ];
      }
      return null;
    });

    final devices = await PrysmLinuxAudio.listInputDevices();
    expect(devices, hasLength(1));
    expect(devices.first.id, 'alsa_input.test');
    expect(devices.first.name, 'Test Mic');
    expect(devices.first.isDefault, isTrue);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, null);
  });
}
