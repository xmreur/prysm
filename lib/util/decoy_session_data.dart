import 'package:prysm/models/contact.dart';
import 'package:prysm/models/conversation.dart';
import 'package:prysm/models/conversation_preferences.dart';
import 'package:prysm/models/group.dart';
import 'package:prysm/services/conversation_preferences_service.dart';

/// In-memory fixtures for panic decoy sessions. Never persisted to disk.
class DecoyMessage {
  final String id;
  final String text;
  final bool isMe;
  final int createdAt;
  final String? senderName;

  const DecoyMessage({
    required this.id,
    required this.text,
    required this.isMe,
    required this.createdAt,
    this.senderName,
  });
}

class DecoySessionData {
  DecoySessionData._({
    required this.appUser,
    required this.contacts,
    required this.groups,
    required this.conversations,
    required this.lastMessagePreviews,
    required this.unreadCounts,
    required this.conversationPrefs,
    required this.messagesByConversationId,
  });

  static const identityOnion =
      'marwkxqyh2g7pz5n3c8vfr4j6t9b2d7l0s5h8k1m4q6w9x3z7a2e5g8j.onion';

  static const _fakeIdentityJson =
      '{"crypto":"v2","signPublic":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=","agreePublic":"BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=","fingerprint":"decoy"}';

  final Contact appUser;
  final List<Contact> contacts;
  final List<Group> groups;
  final List<Conversation> conversations;
  final Map<String, String> lastMessagePreviews;
  final Map<String, int> unreadCounts;
  final Map<String, ConversationPreferences> conversationPrefs;
  final Map<String, List<DecoyMessage>> messagesByConversationId;

  static int _minutesAgo(int minutes) =>
      DateTime.now().subtract(Duration(minutes: minutes)).millisecondsSinceEpoch;

  static int _hoursAgo(int hours) =>
      DateTime.now().subtract(Duration(hours: hours)).millisecondsSinceEpoch;

  static int _daysAgo(int days) =>
      DateTime.now().subtract(Duration(days: days)).millisecondsSinceEpoch;

  static DecoySessionData build() {
    final now = DateTime.now().millisecondsSinceEpoch;

    const alexOnion =
        'jbht7k3m9nq5w2x8c4v6f1r0z7a5e2g8j4l6s9h3k5m7q9w1x3z5a7c9e2g4j6t8.onion';
    const samOnion =
        'k5m7q9w1x3z5a7c9e2g4j6t8b2d4f6h8j0l2n4p6r8t0v2x4z6b8d0f2h4j6l8n.onion';
    const momOnion =
        'n4p6r8t0v2x4z6b8d0f2h4j6l8n0p2r4t6v8x0z2b4d6f8h0j2l4n6p8r0t2v4.onion';
    const chrisOnion =
        'p6r8t0v2x4z6b8d0f2h4j6l8n0p2r4t6v8x0z2b4d6f8h0j2l4n6p8r0t2v4x6.onion';

    final appUser = Contact(
      id: identityOnion,
      name: 'My Account',
      avatarUrl: '',
      identityJson: _fakeIdentityJson,
    );

    final alex = Contact(
      id: alexOnion,
      name: 'Alex Chen',
      avatarUrl: '',
      identityJson: _fakeIdentityJson,
      lastMessageTimestamp: _minutesAgo(12),
    );
    final sam = Contact(
      id: samOnion,
      name: 'Sam Rivera',
      avatarUrl: '',
      identityJson: _fakeIdentityJson,
      lastMessageTimestamp: _minutesAgo(47),
    );
    final mom = Contact(
      id: momOnion,
      name: 'Margaret K.',
      customName: 'OF',
      avatarUrl: '',
      identityJson: _fakeIdentityJson,
      lastMessageTimestamp: _hoursAgo(3),
    );
    final chris = Contact(
      id: chrisOnion,
      name: 'Chris',
      avatarUrl: '',
      identityJson: _fakeIdentityJson,
      lastMessageTimestamp: _daysAgo(12),
    );

    final weekendGroup = Group(
      id: 'a3f2c8e1-4b5d-6e7f-8a9b-0c1d2e3f4a5b',
      name: 'Weekend crew',
      createdBy: identityOnion,
      createdAt: _daysAgo(30),
      lastMessageTimestamp: _minutesAgo(28),
    );

    final contacts = [alex, sam, mom, chris];
    final groups = [weekendGroup];

    final conversations = <Conversation>[
      DirectConversation(alex),
      GroupConversation(weekendGroup),
      DirectConversation(sam),
      DirectConversation(mom),
      DirectConversation(chris),
    ];

    final lastMessagePreviews = <String, String>{
      alexOnion: 'See you tomorrow!',
      weekendGroup.id: "Alex: who's bringing snacks?",
      samOnion: '👍',
      momOnion: 'Love you too ❤️',
      chrisOnion: 'Thanks for everything!',
    };

    final unreadCounts = <String, int>{
      alexOnion: 2,
      weekendGroup.id: 1,
    };

    final conversationPrefs = <String, ConversationPreferences>{
      alexOnion: ConversationPreferences(
        conversationId: alexOnion,
        isPinned: true,
        pinnedAt: now - 86400000,
      ),
      chrisOnion: ConversationPreferences(
        conversationId: chrisOnion,
        isArchived: true,
        archivedAt: _daysAgo(5),
      ),
    };

    ConversationPreferencesService.sortConversations(conversations, conversationPrefs);

    final messagesByConversationId = <String, List<DecoyMessage>>{
      alexOnion: [
        DecoyMessage(
          id: 'd1',
          text: 'Hey, are we still on for coffee Friday?',
          isMe: false,
          createdAt: _hoursAgo(5),
        ),
        DecoyMessage(
          id: 'd2',
          text: 'Yeah definitely — 10 at the usual place?',
          isMe: true,
          createdAt: _hoursAgo(4),
        ),
        DecoyMessage(
          id: 'd3',
          text: 'Perfect. I might be 5 min late.',
          isMe: false,
          createdAt: _hoursAgo(4),
        ),
        DecoyMessage(
          id: 'd4',
          text: 'No worries, see you tomorrow!',
          isMe: false,
          createdAt: _minutesAgo(12),
        ),
      ],
      samOnion: [
        DecoyMessage(
          id: 'd5',
          text: 'Did you finish the slides?',
          isMe: true,
          createdAt: _hoursAgo(2),
        ),
        DecoyMessage(
          id: 'd6',
          text: 'Just sent them over',
          isMe: false,
          createdAt: _hoursAgo(1),
        ),
        DecoyMessage(
          id: 'd7',
          text: '👍',
          isMe: false,
          createdAt: _minutesAgo(47),
        ),
      ],
      momOnion: [
        DecoyMessage(
          id: 'd8',
          text: 'Call me when you get a chance',
          isMe: false,
          createdAt: _hoursAgo(5),
        ),
        DecoyMessage(
          id: 'd9',
          text: 'Will do tonight, love you!',
          isMe: true,
          createdAt: _hoursAgo(4),
        ),
        DecoyMessage(
          id: 'd10',
          text: 'Love you too ❤️',
          isMe: false,
          createdAt: _hoursAgo(3),
        ),
      ],
      chrisOnion: [
        DecoyMessage(
          id: 'd11',
          text: 'Good luck at the new job!',
          isMe: true,
          createdAt: _daysAgo(12),
        ),
        DecoyMessage(
          id: 'd12',
          text: 'Thanks for everything!',
          isMe: false,
          createdAt: _daysAgo(12),
        ),
      ],
      weekendGroup.id: [
        DecoyMessage(
          id: 'd13',
          text: 'Hike on Saturday?',
          isMe: false,
          senderName: 'Sam',
          createdAt: _hoursAgo(6),
        ),
        DecoyMessage(
          id: 'd14',
          text: "I'm in if weather holds",
          isMe: true,
          createdAt: _hoursAgo(5),
        ),
        DecoyMessage(
          id: 'd15',
          text: "who's bringing snacks?",
          isMe: false,
          senderName: 'Alex',
          createdAt: _minutesAgo(28),
        ),
      ],
    };

    return DecoySessionData._(
      appUser: appUser,
      contacts: contacts,
      groups: groups,
      conversations: conversations,
      lastMessagePreviews: lastMessagePreviews,
      unreadCounts: unreadCounts,
      conversationPrefs: conversationPrefs,
      messagesByConversationId: messagesByConversationId,
    );
  }
}
