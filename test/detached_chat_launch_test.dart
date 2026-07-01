import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/models/detached_chat_launch.dart';

void main() {
  group('DetachedChatLaunch', () {
    test('parse empty arguments as main window', () {
      final launch = DetachedChatLaunch.parse('');
      expect(launch.isMain, isTrue);
      expect(launch.chatKind, isNull);
    });

    test('round-trips detached direct payload', () {
      const original = DetachedChatLaunch.detached(
        chatKind: DetachedChatKind.direct,
        conversationId: 'peer.onion',
        title: 'Alice',
        userId: 'me.onion',
        userName: 'Me',
        avatarBase64: 'abc',
        peerPublicKeyPem: '{"k":"v"}',
        themeIndex: 2,
      );

      final decoded = DetachedChatLaunch.parse(original.toArguments());
      expect(decoded.isMain, isFalse);
      expect(decoded.chatKind, DetachedChatKind.direct);
      expect(decoded.conversationId, 'peer.onion');
      expect(decoded.title, 'Alice');
      expect(decoded.userId, 'me.onion');
      expect(decoded.userName, 'Me');
      expect(decoded.avatarBase64, 'abc');
      expect(decoded.peerPublicKeyPem, '{"k":"v"}');
      expect(decoded.themeIndex, 2);
    });

    test('round-trips detached group payload', () {
      const original = DetachedChatLaunch.detached(
        chatKind: DetachedChatKind.group,
        conversationId: 'group-1',
        title: 'Team',
        userId: 'me.onion',
        userName: 'Me',
      );

      final decoded = DetachedChatLaunch.parse(original.toArguments());
      expect(decoded.chatKind, DetachedChatKind.group);
      expect(decoded.conversationId, 'group-1');
      expect(decoded.title, 'Team');
    });
  });
}
