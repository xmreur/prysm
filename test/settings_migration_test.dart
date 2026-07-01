import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/services/settings_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({
      'app_settings': '{not valid json',
    });
  });

  test('init survives corrupt app_settings JSON', () async {
    final service = SettingsService();
    await expectLater(service.init(), completes);
    expect(service.themeMode, isA<int>());
  });
}
