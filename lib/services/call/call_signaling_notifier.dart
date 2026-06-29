import 'dart:async';

import 'package:flutter/foundation.dart';

enum CallSignalOp {
  offer,
  answer,
  end,
  mute,
}

CallSignalOp? callSignalOpFromWire(String op) {
  switch (op) {
    case 'call_offer':
      return CallSignalOp.offer;
    case 'call_answer':
      return CallSignalOp.answer;
    case 'call_end':
      return CallSignalOp.end;
    case 'call_mute':
      return CallSignalOp.mute;
    default:
      return null;
  }
}

class CallSignalEvent {
  const CallSignalEvent({
    required this.peerOnion,
    required this.op,
    required this.payload,
  });

  final String peerOnion;
  final CallSignalOp op;
  final Map<String, dynamic> payload;

  String? get callId => payload['callId'] as String?;
}

/// Broadcast hub for inbound call signaling frames.
class CallSignalingNotifier extends ChangeNotifier {
  CallSignalingNotifier._();

  static CallSignalingNotifier? testInstance;

  static CallSignalingNotifier get instance {
    if (testInstance != null) return testInstance!;
    return _instance ??= CallSignalingNotifier._();
  }

  static CallSignalingNotifier get active => instance;

  static CallSignalingNotifier? _instance;

  final _eventsController = StreamController<CallSignalEvent>.broadcast();

  Stream<CallSignalEvent> get events => _eventsController.stream;

  @visibleForTesting
  factory CallSignalingNotifier() => CallSignalingNotifier._();

  void applyInbound(
    String peerOnion,
    String op,
    Map<String, dynamic> payload,
  ) {
    final signalOp = callSignalOpFromWire(op);
    if (signalOp == null) return;
    if (!_eventsController.isClosed) {
      _eventsController.add(
        CallSignalEvent(
          peerOnion: peerOnion,
          op: signalOp,
          payload: payload,
        ),
      );
    }
  }

  @override
  void dispose() {
    _eventsController.close();
    super.dispose();
  }
}
