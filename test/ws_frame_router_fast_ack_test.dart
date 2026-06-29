import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/server/inbound_message_router.dart';
import 'package:prysm/services/settings_service.dart';
import 'package:prysm/transport/ws_frame_router.dart';
import 'package:prysm/transport/ws_protocol.dart';
import 'package:prysm/util/key_manager.dart';

void main() {
  test('message ack returns before async process completes', () async {
    final inbound = _SlowProcessRouter();
    final router = WsFrameRouter()..routerOverride = inbound;

    const payload = {
      'id': 'msg-1',
      'senderId': 'aaa.onion',
      'receiverId': 'bbb.onion',
      'message': 'cipher',
      'type': 'text',
      'timestamp': 1,
    };

    final responses = await router.handleInboundFrame(
      const WsFrame(op: 'message', id: 'req-1', payload: payload),
    );

    expect(responses, hasLength(1));
    final ack = WsFrame.decode(responses.first);
    expect(ack.op, 'message_ack');
    expect(ack.id, 'req-1');
    expect(inbound.processStarted.isCompleted, isTrue);
    expect(inbound.processFinished.isCompleted, isFalse);

    inbound.allowProcessComplete.complete();
    await inbound.processFinished.future;
  });
}

class _SlowProcessRouter extends InboundMessageRouter {
  _SlowProcessRouter()
      : super(
          keyManager: KeyManager(),
          settings: SettingsService(),
          localOnionAddress: () => 'bbb.onion',
        );

  final processStarted = Completer<void>();
  final processFinished = Completer<void>();
  final allowProcessComplete = Completer<void>();

  @override
  Future<InboundHandleResult> processMessage(Map<String, dynamic> data) async {
    if (!processStarted.isCompleted) {
      processStarted.complete();
    }
    await allowProcessComplete.future;
    if (!processFinished.isCompleted) {
      processFinished.complete();
    }
    return InboundHandleResult.ok({'status': 'received', 'id': data['id']});
  }
}
