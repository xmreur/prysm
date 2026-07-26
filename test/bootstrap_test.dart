// Fase 5B: characterizes lib/app/bootstrap.dart, extracted from
// main._runMainApp. Style mirrors test/main_startup_platform_test.dart
// (closure injection instead of real Flutter/platform bindings).
import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/app/bootstrap.dart';
import 'package:prysm/util/key_manager.dart';

void main() {
  group('SingleInstanceGuard', () {
    test('no lock file yet: writes the current pid, no other instance', () async {
      final files = <String, String>{};
      final guard = SingleInstanceGuard(
        fileExists: (path) async => files.containsKey(path),
        readFile: (path) async => files[path]!,
        checkProcessRunning: (_) async => true,
        writeFile: (path, pid) async => files[path] = pid,
      );

      final other = await guard.detectRunningInstance(
        lockFilePath: '/tmp/.lock',
        currentPid: '111',
      );

      expect(other, isNull);
      expect(files['/tmp/.lock'], '111');
    });

    test('lock file with a dead pid: overwrites it, no other instance', () async {
      final files = <String, String>{'/tmp/.lock': '999'};
      final guard = SingleInstanceGuard(
        fileExists: (path) async => files.containsKey(path),
        readFile: (path) async => files[path]!,
        checkProcessRunning: (pid) async => false,
        writeFile: (path, pid) async => files[path] = pid,
      );

      final other = await guard.detectRunningInstance(
        lockFilePath: '/tmp/.lock',
        currentPid: '222',
      );

      expect(other, isNull);
      expect(files['/tmp/.lock'], '222');
    });

    test('lock file with a live pid: reports the other instance, does not overwrite', () async {
      final files = <String, String>{'/tmp/.lock': '999'};
      final guard = SingleInstanceGuard(
        fileExists: (path) async => files.containsKey(path),
        readFile: (path) async => files[path]!,
        checkProcessRunning: (pid) async => pid == 999,
        writeFile: (path, pid) async => files[path] = pid,
      );

      final other = await guard.detectRunningInstance(
        lockFilePath: '/tmp/.lock',
        currentPid: '222',
      );

      expect(other, 999);
      expect(files['/tmp/.lock'], '999', reason: 'must not overwrite while another instance is live');
    });

    test('lock file with an unparseable pid: treated as dead, overwritten', () async {
      final files = <String, String>{'/tmp/.lock': 'not-a-pid'};
      final guard = SingleInstanceGuard(
        fileExists: (path) async => files.containsKey(path),
        readFile: (path) async => files[path]!,
        checkProcessRunning: (_) async => true,
        writeFile: (path, pid) async => files[path] = pid,
      );

      final other = await guard.detectRunningInstance(
        lockFilePath: '/tmp/.lock',
        currentPid: '222',
      );

      expect(other, isNull);
      expect(files['/tmp/.lock'], '222');
    });
  });

  group('AppBootstrap.initializeServices', () {
    test('runs every init step in order, then starts the server', () async {
      final calls = <String>[];
      final keyManager = KeyManager();

      final result = await AppBootstrap.initializeServices(
        keyManager: keyManager,
        initSettings: () async => calls.add('settings'),
        initPeerTransportRegistry: () async => calls.add('peerTransportRegistry'),
        initBatterySaver: () async => calls.add('batterySaver'),
        initNotificationMute: () async => calls.add('notificationMute'),
        initBlockService: () async => calls.add('blockService'),
        startServer: () async => calls.add('server'),
      );

      expect(calls, [
        'settings',
        'peerTransportRegistry',
        'batterySaver',
        'notificationMute',
        'blockService',
        'server',
      ]);
      expect(result.keyManager, same(keyManager));
      expect(result.startupError, isNull);
      expect(result.serverBindFailed, isFalse);
    });

    test('BlockService init failure sets startupError but still starts the server', () async {
      var serverStarted = false;

      final result = await AppBootstrap.initializeServices(
        keyManager: KeyManager(),
        initSettings: () async {},
        initPeerTransportRegistry: () async {},
        initBatterySaver: () async {},
        initNotificationMute: () async {},
        initBlockService: () async => throw StateError('boom'),
        startServer: () async => serverStarted = true,
      );

      expect(result.startupError, contains('boom'));
      expect(result.serverBindFailed, isFalse);
      expect(serverStarted, isTrue);
    });

    test('server start failure sets serverBindFailed, does not set startupError', () async {
      final result = await AppBootstrap.initializeServices(
        keyManager: KeyManager(),
        initSettings: () async {},
        initPeerTransportRegistry: () async {},
        initBatterySaver: () async {},
        initNotificationMute: () async {},
        initBlockService: () async {},
        startServer: () async => throw StateError('bind failed'),
      );

      expect(result.startupError, isNull);
      expect(result.serverBindFailed, isTrue);
    });
  });

  group('AppBootstrap.showDesktopWindow', () {
    test('runs ensureInitialized -> setTitleBarStyle -> show -> focus -> initTray in order', () async {
      final calls = <String>[];

      await AppBootstrap.showDesktopWindow(
        ensureInitialized: () async => calls.add('ensureInitialized'),
        setTitleBarStyle: () async => calls.add('setTitleBarStyle'),
        show: () async => calls.add('show'),
        focus: () async => calls.add('focus'),
        initTray: () async => calls.add('initTray'),
      );

      expect(calls, [
        'ensureInitialized',
        'setTitleBarStyle',
        'show',
        'focus',
        'initTray',
      ]);
    });
  });

  group('isProcessRunning', () {
    test('returns false for a command that cannot be run / pid not found', () async {
      // pid 0 is never a real user process on POSIX; on the CI/dev Linux
      // environment `kill -0 0` targets the process group and can behave
      // oddly, so use an implausibly large pid instead to stay platform-
      // neutral for "definitely not running".
      final running = await isProcessRunning(999999999);
      expect(running, isFalse);
    });
  });
}
