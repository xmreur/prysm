import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:prysm/server/inbound_message_router.dart';
import 'package:prysm/server/PrysmServer.dart';
import 'package:prysm/util/typing_indicator_notifier.dart';
import 'package:prysm/transport/ws_protocol.dart';

/// Routes inbound WebSocket frames received on outbound peer connections.
class WsInboundDispatcher {
  WsInboundDispatcher._();

  static final WsInboundDispatcher instance = WsInboundDispatcher._();

  final Map<String, StreamSubscription<Map<String, dynamic>>> _subscriptions =
      {};

  InboundMessageRouter? get _router =>
      _routerOverride ?? PrysmServer.instance?.inboundRouter;

  InboundMessageRouter? _routerOverride;

  @visibleForTesting
  set routerOverride(InboundMessageRouter? router) => _routerOverride = router;

  void attach(String peerOnion, Stream<Map<String, dynamic>> stream) {
    detach(peerOnion);
    _subscriptions[peerOnion] = stream.listen(
      (frame) => unawaited(_handleFrame(frame)),
      onError: (Object e) => debugPrint('WsInboundDispatcher $peerOnion: $e'),
    );
  }

  void detach(String peerOnion) {
    unawaited(_subscriptions.remove(peerOnion)?.cancel());
  }

  void resetForTest() {
    for (final sub in _subscriptions.values) {
      unawaited(sub.cancel());
    }
    _subscriptions.clear();
    _routerOverride = null;
  }

  @visibleForTesting
  Future<void> handleFrameForTest(Map<String, dynamic> frame) =>
      _handleFrame(frame);

  Future<void> _handleFrame(Map<String, dynamic> frame) async {
    final op = frame['op'];
    if (op is! String) return;

    if (WsFrame.isTypingOp(op)) {
      final payload = frame['payload'];
      if (payload is Map<String, dynamic>) {
        TypingIndicatorNotifier.instance.applyInbound(payload);
      }
      return;
    }

    final router = _router;
    if (router == null) return;

    if (op == 'message' || WsFrame.isInboundSideChannelOp(op)) {
      final payload = frame['payload'];
      if (payload is! Map<String, dynamic>) return;
      final validation = router.validateMessage(payload);
      if (validation != null) return;
      unawaited(() async {
        try {
          final result = await router.processMessage(payload);
          if (result.statusCode >= 400) {
            debugPrint(
              'WsInboundDispatcher $op failed after push: '
              '${result.jsonBody?['error'] ?? result.statusCode}',
            );
          }
        } catch (e, stack) {
          debugPrint('WsInboundDispatcher message error: $e\n$stack');
        }
      }());
      return;
    }

    if (op == 'sync-hint') {
      final payload = frame['payload'];
      if (payload is! Map<String, dynamic>) return;
      try {
        await router.handleSyncHint(payload);
      } catch (e, stack) {
        debugPrint('WsInboundDispatcher sync-hint error: $e\n$stack');
      }
    }
  }
}
