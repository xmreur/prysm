import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/services/ws_inbound_dispatcher.dart';

void main() {
  tearDown(() {
    WsInboundDispatcher.instance.resetForTest();
  });

  test('ignores frames when router is unavailable', () async {
    WsInboundDispatcher.instance.routerOverride = null;
    await WsInboundDispatcher.instance.handleFrameForTest({
      'op': 'message',
      'payload': {'id': '1'},
    });
  });

  test('ignores message frames without map payload', () async {
    await WsInboundDispatcher.instance.handleFrameForTest({
      'op': 'message',
      'payload': 'not-a-map',
    });
  });
}
