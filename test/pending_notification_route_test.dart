import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/services/pending_notification_route.dart';
import 'package:prysm/util/notification_service.dart';

void main() {
  group('PendingNotificationRoute', () {
    test('parses direct message payload', () {
      final route = PendingNotificationRoute.fromPayload(
        '{"senderId":"alice.onion","groupId":null,"conversationType":"direct"}',
      );

      expect(route, isNotNull);
      expect(route!.senderId, 'alice.onion');
      expect(route.groupId, isNull);
      expect(route.isGroup, isFalse);
    });

    test('parses group payload', () {
      final route = PendingNotificationRoute.fromPayload(
        '{"senderId":"alice.onion","groupId":"group-1","conversationType":"group"}',
      );

      expect(route, isNotNull);
      expect(route!.groupId, 'group-1');
      expect(route.isGroup, isTrue);
    });

    test('returns null for invalid payload', () {
      expect(PendingNotificationRoute.fromPayload('not-json'), isNull);
      expect(PendingNotificationRoute.fromPayload('{}'), isNull);
    });

    test('round-trips through toPayload', () {
      const route = PendingNotificationRoute(
        senderId: 'alice.onion',
        groupId: 'group-1',
        conversationType: 'group',
      );

      final parsed = PendingNotificationRoute.fromPayload(route.toPayload());
      expect(parsed?.senderId, 'alice.onion');
      expect(parsed?.groupId, 'group-1');
      expect(parsed?.conversationType, 'group');
    });
  });

  group('PendingNotificationRouteStore', () {
    tearDown(() {
      PendingNotificationRouteStore.instance.clear();
    });

    test('set take and peek', () {
      final store = PendingNotificationRouteStore.instance;
      expect(store.peek(), isNull);

      store.setFromPayload('{"senderId":"bob.onion"}');
      expect(store.peek()?.senderId, 'bob.onion');

      final taken = store.take();
      expect(taken?.senderId, 'bob.onion');
      expect(store.peek(), isNull);
    });
  });

  group('NotificationService.notificationIdFor', () {
    test('uses group id when present', () {
      final groupId = NotificationService.notificationIdFor(
        groupId: 'group-1',
        senderId: 'alice.onion',
      );
      final senderOnly = NotificationService.notificationIdFor(
        senderId: 'alice.onion',
      );

      expect(groupId, isNot(senderOnly));
      expect(groupId, NotificationService.notificationIdFor(
        groupId: 'group-1',
        senderId: 'bob.onion',
      ));
    });
  });
}
