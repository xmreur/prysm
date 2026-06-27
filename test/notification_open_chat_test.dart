import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/models/contact.dart';
import 'package:prysm/models/group.dart';
import 'package:prysm/services/notification_open_chat_resolver.dart';
import 'package:prysm/util/notification_preview.dart';

void main() {
  group('NotificationOpenChatResolver memory lookup', () {
    final contacts = [
      Contact(
        id: 'alice.onion',
        name: 'Alice',
        avatarUrl: '',
        publicKeyPem: 'pem',
      ),
    ];

    final groups = [
      Group(
        id: 'group-1',
        name: 'Team',
        createdBy: 'alice.onion',
        createdAt: 1,
      ),
    ];

    test('finds contact in memory', () {
      final contact = NotificationOpenChatResolver.findContactInMemory(
        contacts,
        'alice.onion',
      );
      expect(contact?.displayName, 'Alice');
    });

    test('finds group in memory', () {
      final group = NotificationOpenChatResolver.findGroupInMemory(
        groups,
        'group-1',
      );
      expect(group?.name, 'Team');
    });

    test('returns null when not found in memory', () {
      expect(
        NotificationOpenChatResolver.findContactInMemory(contacts, 'missing'),
        isNull,
      );
      expect(
        NotificationOpenChatResolver.findGroupInMemory(groups, 'missing'),
        isNull,
      );
    });
  });

  group('notification preview helpers', () {
    test('uses group name for group title', () {
      expect(
        notificationTitleForInbound(
          isGroup: true,
          senderName: 'Alice',
          groupName: 'Team chat',
        ),
        'Team chat',
      );
    });

    test('builds group body with sender prefix for media', () {
      expect(
        notificationBodyForInbound(
          type: 'group_image',
          isGroup: true,
          senderName: 'Alice',
        ),
        'Alice: 📷 Photo',
      );
    });

    test('truncates long bodies', () {
      final body = truncateNotificationBody('a' * 100, maxLength: 20);
      expect(body.length, lessThanOrEqualTo(20));
      expect(body.endsWith('…'), isTrue);
    });
  });
}
