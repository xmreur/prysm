import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/util/tor_outbound_gateway.dart';
import 'package:prysm/util/tor_service.dart';

void main() {
  setUp(() {
    TorOutboundGateway.resetForTest();
    TorOutboundGateway.configure(
      TorManager(torPath: '/bin/false', dataDir: '/tmp/gateway-test'),
    );
  });

  tearDown(TorOutboundGateway.resetForTest);

  group('TorOutboundGateway per-peer queue', () {
    test('serializes operations for the same peer', () async {
      final gateway = TorOutboundGateway.instance;
      final log = <String>[];

      Future<void> op(String name) {
        return gateway.runForPeer('peer1.onion', () async {
          log.add('$name-start');
          await Future<void>.delayed(const Duration(milliseconds: 5));
          log.add('$name-end');
        });
      }

      await Future.wait([op('a'), op('b')]);
      expect(log, ['a-start', 'a-end', 'b-start', 'b-end']);
    });

    test('allows another peer while first peer operation is in flight', () async {
      final gateway = TorOutboundGateway.instance;
      final peerAStarted = Completer<void>();
      final peerBStarted = Completer<void>();

      final peerAFuture = gateway.runForPeer('peer-a.onion', () async {
        peerAStarted.complete();
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });

      await peerAStarted.future;
      final peerBFuture = gateway.runForPeer('peer-b.onion', () async {
        peerBStarted.complete();
      });

      await peerBStarted.future.timeout(const Duration(milliseconds: 30));
      await Future.wait([peerAFuture, peerBFuture]);
    });
  });
}
