import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/models/detached_chat_launch.dart';
import 'package:prysm/util/app_bootstrap.dart';

void main() {
  group('shouldUseDetachedWindowBootstrap', () {
    test('mobile skips desktop multi-window', () {
      expect(shouldUseDetachedWindowBootstrap(isDesktop: false), isFalse);
    });

    test('desktop uses multi-window routing', () {
      expect(shouldUseDetachedWindowBootstrap(isDesktop: true), isTrue);
    });
  });

  group('bootstrapApp', () {
    test('mobile runs main app without reading engine arguments', () async {
      var mainRan = false;
      var detachedRan = false;
      var readArgsCalled = false;

      await bootstrapApp(
        isDesktop: false,
        readEngineArguments: () async {
          readArgsCalled = true;
          throw StateError('WindowController must not be used on mobile');
        },
        runMainApp: () async {
          mainRan = true;
        },
        runDetachedApp: (_) async {
          detachedRan = true;
        },
      );

      expect(mainRan, isTrue);
      expect(detachedRan, isFalse);
      expect(readArgsCalled, isFalse);
    });

    test('desktop main window runs main app', () async {
      var mainRan = false;

      await bootstrapApp(
        isDesktop: true,
        readEngineArguments: () async => '{"windowKind":"main"}',
        runMainApp: () async {
          mainRan = true;
        },
        runDetachedApp: (_) async {},
      );

      expect(mainRan, isTrue);
    });

    test('desktop detached window runs detached app', () async {
      var mainRan = false;
      var detachedRan = false;
      DetachedChatLaunch? launch;

      await bootstrapApp(
        isDesktop: true,
        readEngineArguments: () async =>
            '{"windowKind":"detached","chatKind":"direct","conversationId":"peer.onion","userId":"me.onion","userName":"Me"}',
        runMainApp: () async {
          mainRan = true;
        },
        runDetachedApp: (l) async {
          detachedRan = true;
          launch = l;
        },
      );

      expect(mainRan, isFalse);
      expect(detachedRan, isTrue);
      expect(launch?.chatKind, DetachedChatKind.direct);
      expect(launch?.conversationId, 'peer.onion');
    });
  });
}
