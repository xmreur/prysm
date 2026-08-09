import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/server/inbound_message_router.dart';
import 'package:prysm/services/settings_service.dart';
import 'package:prysm/transport/ws_frame_router.dart';
import 'package:prysm/transport/ws_protocol.dart';
import 'package:prysm/util/key_manager.dart';

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

  test('message_modify is verified before ack: a processing failure is not '
      'acked', () async {
    final router = WsFrameRouter()..routerOverride = _FailingModifyRouter();

    const payload = {
      'id': 'modify-1',
      'senderId': 'aaa.onion',
      'receiverId': 'bbb.onion',
      'message': 'cipher',
      'type': 'message_modify',
      'timestamp': 1,
    };

    final responses = await router.handleInboundFrame(
      const WsFrame(op: 'message_modify', id: 'req-1', payload: payload),
    );

    expect(responses, hasLength(1));
    final frame = WsFrame.decode(responses.first);
    expect(frame.op, 'error');
    expect(frame.id, 'req-1');
  });

  test('message_modify still acks when processing succeeds', () async {
    final router = WsFrameRouter()..routerOverride = _OkModifyRouter();

    const payload = {
      'id': 'modify-2',
      'senderId': 'aaa.onion',
      'receiverId': 'bbb.onion',
      'message': 'cipher',
      'type': 'message_modify',
      'timestamp': 1,
    };

    final responses = await router.handleInboundFrame(
      const WsFrame(op: 'message_modify', id: 'req-2', payload: payload),
    );

    expect(responses, hasLength(1));
    final frame = WsFrame.decode(responses.first);
    expect(frame.op, 'message_modify_ack');
    expect(frame.id, 'req-2');
  });

  test('other side-channel ops keep the optimistic fast ack', () async {
    final inbound = _SlowSideChannelRouter();
    final router = WsFrameRouter()..routerOverride = inbound;

    const payload = {
      'id': 'rr-1',
      'senderId': 'aaa.onion',
      'receiverId': 'bbb.onion',
      'message': 'cipher',
      'type': 'read_receipt',
      'timestamp': 1,
    };

    final responses = await router.handleInboundFrame(
      const WsFrame(op: 'read_update', id: 'req-3', payload: payload),
    );

    expect(responses, hasLength(1));
    final ack = WsFrame.decode(responses.first);
    expect(ack.op, 'read_update_ack');
    expect(ack.id, 'req-3');
    // The ack is sent while async processing is still in flight.
    expect(inbound.processStarted.isCompleted, isTrue);
    expect(inbound.processFinished.isCompleted, isFalse);

    inbound.allowProcessComplete.complete();
    await inbound.processFinished.future;
  });
}

class _FailingModifyRouter extends InboundMessageRouter {
  _FailingModifyRouter()
      : super(
          keyManager: KeyManager(),
          settings: SettingsService(),
          localOnionAddress: () => 'bbb.onion',
        );

  @override
  Future<InboundHandleResult> processMessage(Map<String, dynamic> data) async {
    return InboundHandleResult.internalError('modify rejected');
  }
}

class _OkModifyRouter extends InboundMessageRouter {
  _OkModifyRouter()
      : super(
          keyManager: KeyManager(),
          settings: SettingsService(),
          localOnionAddress: () => 'bbb.onion',
        );

  @override
  Future<InboundHandleResult> processMessage(Map<String, dynamic> data) async {
    return InboundHandleResult.ok({'status': 'received', 'id': data['id']});
  }
}

class _SlowSideChannelRouter extends InboundMessageRouter {
  _SlowSideChannelRouter()
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
