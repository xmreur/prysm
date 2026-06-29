import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/services/call/call_signaling_notifier.dart';
import 'package:prysm/services/ws_inbound_dispatcher.dart';
import 'package:prysm/transport/ws_frame_router.dart';
import 'package:prysm/transport/ws_protocol.dart';

void main() {
  late CallSignalingNotifier notifier;

  setUp(() {
    notifier = CallSignalingNotifier();
    CallSignalingNotifier.testInstance = notifier;
  });

  tearDown(() {
    CallSignalingNotifier.testInstance = null;
    WsInboundDispatcher.instance.resetForTest();
  });

  test('WsFrameRouter forwards call_offer to CallSignalingNotifier', () async {
    final events = <CallSignalEvent>[];
    final sub = notifier.events.listen(events.add);

    final router = WsFrameRouter();
    await router.handleInboundFrame(
      const WsFrame(
        op: 'call_offer',
        payload: {'callId': 'abc'},
      ),
      peerOnion: 'peer.onion',
    );

    await Future<void>.delayed(Duration.zero);
    await sub.cancel();

    expect(events, hasLength(1));
    expect(events.single.op, CallSignalOp.offer);
    expect(events.single.peerOnion, 'peer.onion');
    expect(events.single.callId, 'abc');
  });

  test('WsInboundDispatcher forwards call_answer on outbound link', () async {
    final events = <CallSignalEvent>[];
    final sub = notifier.events.listen(events.add);

    await WsInboundDispatcher.instance.handleFrameForTest('peer.onion', {
      'op': 'call_answer',
      'payload': {'callId': 'xyz'},
    });

    await sub.cancel();

    expect(events, hasLength(1));
    expect(events.single.op, CallSignalOp.answer);
    expect(events.single.callId, 'xyz');
  });
}
