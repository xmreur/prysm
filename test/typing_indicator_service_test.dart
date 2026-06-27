import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/services/settings_service.dart';
import 'package:prysm/services/typing_indicator_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TypingIndicatorService', () {
    late List<Map<String, dynamic>> sent;

    setUp(() async {
      sent = [];
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsService();
      await settings.init();
      await settings.setEnableTypingIndicators(true);
    });

    TypingIndicatorService directService({
      SettingsService? settings,
    }) {
      return TypingIndicatorService.direct(
        userId: 'me.onion',
        peerId: 'peer.onion',
        settings: settings ?? SettingsService(),
        sendOverride: (peer, payload) async {
          sent.add({'peer': peer, ...payload});
        },
      );
    }

    test('privacy off does not send', () async {
      final settings = SettingsService();
      await settings.setEnableTypingIndicators(false);
      final service = directService(settings: settings);

      service.onComposerTypingChanged(true);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(sent, isEmpty);
      service.dispose();
    });

    test('rapid keystrokes send one start then stop on idle', () async {
      final service = directService();

      service.onComposerTypingChanged(true);
      service.onComposerTypingChanged(true);
      service.onComposerTypingChanged(true);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(sent.where((frame) => frame['typing'] == true).length, 1);

      service.onComposerTypingChanged(false);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(sent.where((frame) => frame['typing'] == false).length, 1);
      service.dispose();
    });

    test('group fan-out excludes self', () async {
      final service = TypingIndicatorService.group(
        userId: 'me.onion',
        groupId: 'group-1',
        memberIds: ['me.onion', 'alice.onion', 'bob.onion'],
        settings: SettingsService(),
        sendOverride: (peer, payload) async {
          sent.add({'peer': peer, ...payload});
        },
      );

      service.onComposerTypingChanged(true);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final peers = sent.map((frame) => frame['peer']).toSet();
      expect(peers, {'alice.onion', 'bob.onion'});
      expect(peers.contains('me.onion'), isFalse);
      service.dispose();
    });
  });
}
