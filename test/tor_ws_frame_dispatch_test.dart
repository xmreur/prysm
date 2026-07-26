import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/client/tor_websocket_client.dart';
import 'package:prysm/transport/ws_protocol.dart';

void main() {
  group('TorWebSocketClient binary frame dispatch', () {
    test('call audio frame is emitted on onBinary', () async {
      final harness = await _connect();
      final frame = <int>[callAudioFrameMagic, 0, 0, 0, 1, 0, 0, 0, 2, 1, 2, 3];

      final received = harness.client.onBinary.first;
      harness.socket.addIncoming(frame);

      expect(await received, frame);
    });

    test('file transfer frame is consumed by onBinaryFrame and not emitted on onBinary',
        () async {
      final captured = <List<int>>[];
      final harness = await _connectWithBinaryHandler((raw, _) {
        captured.add(raw);
        return true;
      });
      final frame = <int>[fileTransferChunkMagic, 1, 2, 3];

      final binaryEvents = <List<int>>[];
      final subscription = harness.client.onBinary.listen(binaryEvents.add);
      harness.socket.addIncoming(frame);
      await Future.delayed(Duration.zero);
      await subscription.cancel();

      expect(captured, [frame]);
      expect(binaryEvents, isEmpty);
    });

    test('non-magic binary frame is emitted on onBinary', () async {
      final harness = await _connect();
      final frame = <int>[0xFF, 0xFE, 0xFD];

      final received = harness.client.onBinary.first;
      harness.socket.addIncoming(frame);

      expect(await received, frame);
    });

    test('binary frame that is valid UTF-8 text is handled as text', () async {
      final harness = await _connect();
      final map = <String, dynamic>{'op': 'message', 'payload': <String, dynamic>{'text': 'hi'}};
      final frame = utf8.encode(jsonEncode(map));

      final received = harness.client.onIncoming.first;
      harness.socket.addIncoming(frame);

      expect(await received, map);
    });

    test('text frame is emitted on onIncoming', () async {
      final harness = await _connect();
      final map = <String, dynamic>{'op': 'message', 'payload': <String, dynamic>{'text': 'hi'}};

      final received = harness.client.onIncoming.first;
      harness.socket.addIncoming(jsonEncode(map));

      expect(await received, map);
    });

    test('text call op frame is consumed by onTextFrame and not emitted on onIncoming',
        () async {
      final captured = <Map<String, dynamic>>[];
      final harness = await _connectWithTextHandler((frame) {
        final op = frame['op'];
        if (op is String && WsFrame.isCallOp(op)) {
          captured.add(frame);
          return true;
        }
        return false;
      });
      final map = <String, dynamic>{
        'op': 'call_offer',
        'payload': <String, dynamic>{'callId': 'call-1'},
      };

      final incomingEvents = <Map<String, dynamic>>[];
      final subscription = harness.client.onIncoming.listen(incomingEvents.add);
      harness.socket.addIncoming(jsonEncode(map));
      await Future.delayed(Duration.zero);
      await subscription.cancel();

      expect(captured, [map]);
      expect(incomingEvents, isEmpty);
    });

    test('non-call text frame is emitted on onIncoming even with onTextFrame',
        () async {
      final harness = await _connectWithTextHandler((frame) => false);
      final map = <String, dynamic>{'op': 'message', 'payload': <String, dynamic>{'text': 'hi'}};

      final received = harness.client.onIncoming.first;
      harness.socket.addIncoming(jsonEncode(map));

      expect(await received, map);
    });
  });
}

class _Harness {
  _Harness(this.client, this.socket);

  final TorWebSocketClient client;
  final _FakeWebSocket socket;
}

Future<_Harness> _connect({
  BinaryFrameHandler? onBinaryFrame,
  TextFrameHandler? onTextFrame,
}) async {
  final socket = _FakeWebSocket();
  final client = TorWebSocketClient(
    peerOnion: 'peer.onion',
    socksPort: 9050,
    localOnion: 'local.onion',
    onBinaryFrame: onBinaryFrame,
    onTextFrame: onTextFrame,
    connector: ({required String peerOnion, required int socksPort, Duration? timeout}) async => socket,
  );

  final connectFuture = client.connect();
  await Future.delayed(Duration.zero);
  socket.addIncoming(WsFrame.hello(supports: <String>[]).encode());
  await connectFuture;

  return _Harness(client, socket);
}

Future<_Harness> _connectWithBinaryHandler(BinaryFrameHandler handler) =>
    _connect(onBinaryFrame: handler);

Future<_Harness> _connectWithTextHandler(TextFrameHandler handler) =>
    _connect(onTextFrame: handler);

class _FakeWebSocket extends Stream<dynamic> implements WebSocket {
  final _controller = StreamController<dynamic>.broadcast();
  final List<dynamic> outgoing = [];

  @override
  int get readyState => WebSocket.open;

  @override
  String get extensions => '';

  @override
  String? get protocol => null;

  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;

  @override
  Duration? pingInterval;

  @override
  StreamSubscription<dynamic> listen(
    void Function(dynamic event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return _controller.stream.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  void add(dynamic data) => outgoing.add(data);

  @override
  void addUtf8Text(List<int> bytes) => outgoing.add(bytes);

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<dynamic> stream) async {}

  @override
  Future<void> close([int? closeCode, String? closeReason]) async {
    await _controller.close();
  }

  @override
  Future<void> get done => Future.value();

  void addIncoming(dynamic data) => _controller.add(data);
}
