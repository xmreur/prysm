import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/services/typing_state_tracker.dart';

void main() {
  group('TypingStateTracker', () {
    late TypingStateTracker tracker;

    setUp(() {
      tracker = TypingStateTracker();
    });

    tearDown(() {
      tracker.dispose();
    });

    test('expires typist after 5 seconds without refresh', () async {
      tracker.applyEvent(
        conversationKey: 'conv-1',
        senderId: 'alice.onion',
        typing: true,
        timestamp: DateTime.now().millisecondsSinceEpoch,
      );

      expect(tracker.activeTypists('conv-1'), ['alice.onion']);

      await Future<void>.delayed(const Duration(seconds: 6));

      expect(tracker.activeTypists('conv-1'), isEmpty);
    });

    test('tracks multiple typists in a group conversation', () {
      final now = DateTime.now().millisecondsSinceEpoch;
      tracker.applyEvent(
        conversationKey: 'group-1',
        senderId: 'alice.onion',
        typing: true,
        timestamp: now,
      );
      tracker.applyEvent(
        conversationKey: 'group-1',
        senderId: 'bob.onion',
        typing: true,
        timestamp: now,
      );

      expect(
        tracker.activeTypists('group-1'),
        ['alice.onion', 'bob.onion'],
      );

      tracker.applyEvent(
        conversationKey: 'group-1',
        senderId: 'alice.onion',
        typing: false,
        timestamp: now,
      );

      expect(tracker.activeTypists('group-1'), ['bob.onion']);
    });
  });
}
