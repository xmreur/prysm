import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/models/contact.dart';
import 'package:prysm/models/conversation.dart';
import 'package:prysm/models/conversation_preferences.dart';
import 'package:prysm/models/group.dart';
import 'package:prysm/services/conversation_preferences_service.dart';

void main() {
  test('pinned conversations sort above unpinned by recency', () {
    final a = DirectConversation(Contact(
      id: 'a.onion',
      name: 'A',
      avatarUrl: '',
      publicKeyPem: '',
      lastMessageTimestamp: 1000,
    ));
    final b = DirectConversation(Contact(
      id: 'b.onion',
      name: 'B',
      avatarUrl: '',
      publicKeyPem: '',
      lastMessageTimestamp: 2000,
    ));
    final c = DirectConversation(Contact(
      id: 'c.onion',
      name: 'C',
      avatarUrl: '',
      publicKeyPem: '',
      lastMessageTimestamp: 500,
    ));

    final list = [a, b, c];
    final prefs = {
      'c.onion': const ConversationPreferences(
        conversationId: 'c.onion',
        isPinned: true,
        pinnedAt: 10,
      ),
      'b.onion': const ConversationPreferences(
        conversationId: 'b.onion',
        isPinned: true,
        pinnedAt: 20,
      ),
    };

    ConversationPreferencesService.sortConversations(list, prefs);

    expect(list.map((c) => c.id).toList(), ['b.onion', 'c.onion', 'a.onion']);
  });

  test('group conversations participate in pin ordering', () {
    final group = GroupConversation(Group(
      id: 'g1',
      name: 'Team',
      createdBy: 'x',
      createdAt: 1,
      lastMessageTimestamp: 100,
    ));
    final direct = DirectConversation(Contact(
      id: 'd.onion',
      name: 'D',
      avatarUrl: '',
      publicKeyPem: '',
      lastMessageTimestamp: 9999,
    ));

    final list = [direct, group];
    final prefs = {
      'g1': const ConversationPreferences(
        conversationId: 'g1',
        isPinned: true,
        pinnedAt: 1,
      ),
    };

    ConversationPreferencesService.sortConversations(list, prefs);
    expect(list.first.id, 'g1');
  });
}
