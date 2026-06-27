import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/transport/transport_provider.dart';
import 'package:prysm/util/tor_delivery.dart';
import 'package:prysm/util/tor_outbound_gateway.dart';
import 'package:prysm/util/tor_service.dart';

void main() {
  setUp(() {
    TorOutboundGateway.resetForTest();
    TorDelivery.resetForTest();
    TorOutboundGateway.configure(
      TorManager(torPath: '/bin/false', dataDir: '/tmp/gateway-test'),
    );
  });

  tearDown(() {
    TorOutboundGateway.resetForTest();
    TorDelivery.resetForTest();
  });

  test('TorOutboundGateway is a TransportProvider alias', () {
    expect(TorOutboundGateway.isConfigured, isTrue);
    expect(identical(TorOutboundGateway.instance, TransportProvider.instance), isTrue);
  });

  test('allows concurrent operations for the same peer', () async {
    final gateway = TorOutboundGateway.instance;
    final log = <String>[];

    Future<void> op(String name) {
      return gateway.runForPeer('peer1.onion', () async {
        log.add('$name-start');
        await Future<void>.delayed(const Duration(milliseconds: 20));
        log.add('$name-end');
      });
    }

    await Future.wait([op('a'), op('b')]);
    expect(log.where((e) => e.endsWith('-start')).length, 2);
    expect(log.where((e) => e.endsWith('-end')).length, 2);
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
}
