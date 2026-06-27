import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/services/active_conversation_tracker.dart';

void main() {
  group('ActiveConversationTracker', () {
    tearDown(() {
      ActiveConversationTracker.instance.clear();
    });

    test('matches direct conversation by sender id', () {
      ActiveConversationTracker.instance.setDirect('alice.onion');

      expect(
        ActiveConversationTracker.instance.matchesInbound(
          senderId: 'alice.onion',
        ),
        isTrue,
      );
      expect(
        ActiveConversationTracker.instance.matchesInbound(
          senderId: 'bob.onion',
        ),
        isFalse,
      );
    });

    test('matches group conversation by group id', () {
      ActiveConversationTracker.instance.setGroup('group-1');

      expect(
        ActiveConversationTracker.instance.matchesInbound(
          inboundGroupId: 'group-1',
          senderId: 'alice.onion',
        ),
        isTrue,
      );
      expect(
        ActiveConversationTracker.instance.matchesInbound(
          inboundGroupId: 'group-2',
          senderId: 'alice.onion',
        ),
        isFalse,
      );
    });
  });
}
