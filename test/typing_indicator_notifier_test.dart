import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/services/settings_service.dart';
import 'package:prysm/util/typing_indicator_notifier.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TypingIndicatorNotifier', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsService();
      await settings.init();
      await settings.setEnableTypingIndicators(true);
    });

    test('emits inbound typing events when enabled', () async {
      final events = <TypingIndicatorEvent>[];
      final sub = TypingIndicatorNotifier.instance.events.listen(events.add);

      TypingIndicatorNotifier.instance.applyInbound({
        'senderId': 'alice.onion',
        'receiverId': 'me.onion',
        'typing': true,
        'timestamp': 1710000000000,
      });

      await Future<void>.delayed(Duration.zero);
      expect(events, hasLength(1));
      expect(events.first.senderId, 'alice.onion');
      expect(events.first.typing, isTrue);

      await sub.cancel();
    });

    test('ignores inbound when enableTypingIndicators is false', () async {
      await SettingsService().setEnableTypingIndicators(false);

      final events = <TypingIndicatorEvent>[];
      final sub = TypingIndicatorNotifier.instance.events.listen(events.add);

      TypingIndicatorNotifier.instance.applyInbound({
        'senderId': 'alice.onion',
        'receiverId': 'me.onion',
        'typing': true,
        'timestamp': 1710000000000,
      });

      await Future<void>.delayed(Duration.zero);
      expect(events, isEmpty);

      await sub.cancel();
    });
  });
}
