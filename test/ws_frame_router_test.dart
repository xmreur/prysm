import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/transport/ws_frame_router.dart';
import 'package:prysm/transport/ws_protocol.dart';

void main() {
  test('ping returns pong', () async {
    final router = WsFrameRouter();
    final responses = await router.handleInboundFrame(const WsFrame(op: 'ping'));
    expect(responses, hasLength(1));
    expect(WsFrame.decode(responses.first).op, 'pong');
  });

  test('isLocalRequestOp identifies server-side request ops', () {
    final router = WsFrameRouter();
    expect(router.isLocalRequestOp('get_profile'), isTrue);
    expect(router.isLocalRequestOp('get_public'), isTrue);
    expect(router.isLocalRequestOp('ping'), isTrue);
    expect(router.isLocalRequestOp('message'), isFalse);
  });

  test('isPeerRequest identifies request frames that need an ack', () {
    final router = WsFrameRouter();
    expect(
      router.isPeerRequest(const WsFrame(op: 'message', id: '1')),
      isTrue,
    );
    expect(
      router.isPeerRequest(const WsFrame(op: 'read_update', id: '2')),
      isTrue,
    );
    expect(
      router.isPeerRequest(const WsFrame(op: 'message')),
      isFalse,
    );
    expect(router.isPeerRequest(const WsFrame(op: 'ping')), isTrue);
  });
}
