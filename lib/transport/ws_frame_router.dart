import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:prysm/server/inbound_message_router.dart';
import 'package:prysm/server/PrysmServer.dart';
import 'package:prysm/transport/ws_protocol.dart';
import 'package:prysm/util/typing_indicator_notifier.dart';

/// Handles inbound WebSocket request frames and returns encoded responses.
class WsFrameRouter {
  InboundMessageRouter? get _router =>
      _routerOverride ?? PrysmServer.instance?.inboundRouter;

  InboundMessageRouter? _routerOverride;

  @visibleForTesting
  set routerOverride(InboundMessageRouter? router) => _routerOverride = router;

  /// Returns encoded response frame(s) to write on the link, if any.
  Future<List<String>> handleInboundFrame(WsFrame frame) async {
    if (frame.op == 'ping') {
      return [WsFrame.pong().encode()];
    }

    if (frame.op == 'get_profile') {
      final router = _router;
      if (router == null) return [];
      final result = router.buildProfile();
      return [
        WsFrame.response(
          op: 'profile',
          id: frame.id ?? '',
          payload: result.jsonBody,
        ).encode(),
      ];
    }

    if (frame.op == 'get_public') {
      final router = _router;
      if (router == null) return [];
      final result = router.buildPublicKey();
      return [
        WsFrame.response(
          op: 'public',
          id: frame.id ?? '',
          payload: {'publicKeyPem': result.plainTextBody ?? ''},
        ).encode(),
      ];
    }

    if (frame.op == 'typing_update') {
      final payload = frame.payload;
      if (payload != null) {
        TypingIndicatorNotifier.instance.applyInbound(payload);
      }
      return [];
    }

    if (frame.op == 'message' || WsFrame.isInboundSideChannelOp(frame.op)) {
      final payload = frame.payload;
      if (payload == null) return [];
      final router = _router;
      if (router == null) return [];

      if (kDebugMode) {
        debugPrint(
          'WsFrameRouter ${frame.op} from ${payload['senderId']} '
          'type=${payload['type']}',
        );
      }

      try {
        final result = await router.handleMessage(payload);
        if (frame.id == null) return [];
        final ackOp =
            frame.op == 'message' ? 'message_ack' : '${frame.op}_ack';
        return [
          WsFrame.response(
            op: ackOp,
            id: frame.id!,
            payload: result.jsonBody,
          ).encode(),
        ];
      } catch (e, stack) {
        debugPrint('WsFrameRouter ${frame.op} error: $e\n$stack');
        if (frame.id == null) return [];
        return [
          WsFrame.error(id: frame.id!, message: 'Processing failed').encode(),
        ];
      }
    }

    if (frame.op == 'sync-hint') {
      final payload = frame.payload;
      if (payload == null) return [];
      final router = _router;
      if (router == null) return [];

      try {
        final result = await router.handleSyncHint(payload);
        if (frame.id == null) return [];
        return [
          WsFrame.response(
            op: 'sync-hint_ack',
            id: frame.id!,
            payload: result.jsonBody,
          ).encode(),
        ];
      } catch (e, stack) {
        debugPrint('WsFrameRouter sync-hint error: $e\n$stack');
        if (frame.id == null) return [];
        return [
          WsFrame.error(id: frame.id!, message: 'Processing failed').encode(),
        ];
      }
    }

    return [];
  }

  /// True when the peer sent a request we must answer locally (not a push).
  bool isLocalRequestOp(String op) =>
      op == 'get_profile' || op == 'get_public' || op == 'ping';

  /// Inbound frame from the peer that must be handled locally (and acked when [id] is set).
  bool isPeerRequest(WsFrame frame) {
    if (isLocalRequestOp(frame.op) || WsFrame.isTypingOp(frame.op)) {
      return true;
    }
    if (frame.id == null) return false;
    return WsFrame.routesToMessageHandler(frame.op) || frame.op == 'sync-hint';
  }

  @visibleForTesting
  void resetForTest() {
    _routerOverride = null;
  }
}
