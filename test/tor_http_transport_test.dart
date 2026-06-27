import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/transport/tor_http_transport.dart';
import 'package:prysm/util/tor_delivery.dart';
import 'package:prysm/util/tor_service.dart';

void main() {
  setUp(() {
    TorDelivery.resetForTest();
  });

  tearDown(() {
    TorDelivery.resetForTest();
  });

  group('TorHttpTransport', () {
    test('allows concurrent operations for the same peer', () async {
      final transport = TorHttpTransport.createForTest(
        TorManager(torPath: '/bin/false', dataDir: '/tmp/http-transport-test'),
      );
      final log = <String>[];

      Future<void> op(String name) {
        return transport.runForPeer('peer1.onion', () async {
          log.add('$name-start');
          await Future<void>.delayed(const Duration(milliseconds: 20));
          log.add('$name-end');
        });
      }

      await Future.wait([op('a'), op('b')]);
      expect(log.where((e) => e.endsWith('-start')).length, 2);
      expect(log.where((e) => e.endsWith('-end')).length, 2);
      transport.dispose();
    });

    test('allows another peer while first peer operation is in flight', () async {
      final transport = TorHttpTransport.createForTest(
        TorManager(torPath: '/bin/false', dataDir: '/tmp/http-transport-test-2'),
      );
      final peerAStarted = Completer<void>();
      final peerBStarted = Completer<void>();

      final peerAFuture = transport.runForPeer('peer-a.onion', () async {
        peerAStarted.complete();
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });

      await peerAStarted.future;
      final peerBFuture = transport.runForPeer('peer-b.onion', () async {
        peerBStarted.complete();
      });

      await peerBStarted.future.timeout(const Duration(milliseconds: 30));
      await Future.wait([peerAFuture, peerBFuture]);
      transport.dispose();
    });
  });
}
