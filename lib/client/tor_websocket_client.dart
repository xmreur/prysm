import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:prysm/client/tor_socks_websocket.dart';
import 'package:prysm/transport/ws_frame_router.dart';
import 'package:prysm/transport/ws_protocol.dart';
import 'package:prysm/util/logging.dart';
import 'package:uuid/uuid.dart';

/// Callback invoked for every inbound binary frame.
///
/// Return `true` to consume the frame (it will not be emitted on [onBinary]);
/// return `false` to let the client fall back to its default handling.
typedef BinaryFrameHandler = bool Function(
  List<int> frame,
  Future<void> Function(String op, {Map<String, dynamic>? payload}) sendAck,
);

/// Callback invoked for every inbound text frame before the client applies
/// internal routing (hello, pending request matching, pong, local request).
///
/// Return `true` to consume the frame (it will not be emitted on [onIncoming]
/// and will not be routed locally); return `false` to let the client handle it.
typedef TextFrameHandler = bool Function(Map<String, dynamic> frame);

/// Persistent WebSocket connection to a single peer over Tor SOCKS.
class TorWebSocketClient {
  TorWebSocketClient({
    required this.peerOnion,
    required this.socksPort,
    this.localOnion,
    WsFrameRouter? frameRouter,
    this.onBinaryFrame,
    this.onTextFrame,
    Future<WebSocket> Function({
      required String peerOnion,
      required int socksPort,
      Duration timeout,
    })? connector,
  })  : _frameRouter = frameRouter ?? WsFrameRouter(),
        _connector = connector ?? connectTorWebSocket;

  final String peerOnion;
  final int socksPort;
  final String? localOnion;
  final BinaryFrameHandler? onBinaryFrame;
  final TextFrameHandler? onTextFrame;
  final WsFrameRouter _frameRouter;
  final Future<WebSocket> Function({
    required String peerOnion,
    required int socksPort,
    Duration timeout,
  }) _connector;

  WebSocket? _socket;
  StreamSubscription<dynamic>? _subscription;
  final Map<String, Completer<Map<String, dynamic>>> _pendingRequests = {};
  final _incomingController = StreamController<Map<String, dynamic>>.broadcast();
  final _binaryController = StreamController<List<int>>.broadcast();
  bool _handshakeComplete = false;
  bool _disposed = false;
  bool _disconnecting = false;
  Completer<void>? _helloCompleter;
  List<String> peerSupports = const [];

  Stream<Map<String, dynamic>> get onIncoming => _incomingController.stream;

  Stream<List<int>> get onBinary => _binaryController.stream;

  bool get isConnected =>
      !_disposed && _socket != null && _handshakeComplete;

  Future<void> connect({Duration timeout = const Duration(seconds: 30)}) async {
    if (_disposed) {
      throw StateError('TorWebSocketClient disposed');
    }

    try {
      final socket = await _connector(
        peerOnion: peerOnion,
        socksPort: socksPort,
        timeout: timeout,
      );

      _helloCompleter = Completer<void>();
      _socket = socket;
      _subscription = socket.listen(
        _onMessage,
        onDone: _onDone,
        onError: _onError,
      );

      socket.add(
        WsFrame.hello(onion: localOnion).encode(),
      );
      await _helloCompleter!.future.timeout(timeout);
      _helloCompleter = null;
      _handshakeComplete = true;
    } catch (e) {
      _helloCompleter = null;
      await disconnect();
      rethrow;
    }
  }

  Future<Map<String, dynamic>> request(
    String op, {
    Map<String, dynamic>? payload,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final socket = _socket;
    if (socket == null || !_handshakeComplete) {
      throw StateError('WebSocket not connected to $peerOnion');
    }

    final id = const Uuid().v4();
    final completer = Completer<Map<String, dynamic>>();
    _pendingRequests[id] = completer;

    socket.add(
      WsFrame(op: op, id: id, payload: payload).encode(),
    );

    try {
      return await completer.future.timeout(timeout);
    } finally {
      _pendingRequests.remove(id);
    }
  }

  Future<void> send(
    String op, {
    Map<String, dynamic>? payload,
  }) async {
    final socket = _socket;
    if (socket == null || !_handshakeComplete) {
      throw StateError('WebSocket not connected to $peerOnion');
    }
    socket.add(WsFrame(op: op, payload: payload).encode());
  }

  Future<void> sendBytes(List<int> bytes) async {
    final socket = _socket;
    if (socket == null || !_handshakeComplete) {
      throw StateError('WebSocket not connected to $peerOnion');
    }
    socket.add(bytes);
  }

  Future<void> sendPing() => send('ping');

  void _onMessage(dynamic raw) {
    if (raw is String) {
      _handleTextFrame(raw);
      return;
    }
    if (raw is List<int>) {
      final handler = onBinaryFrame;
      if (handler != null) {
        final consumed = handler(
          raw,
          (op, {payload}) => send(op, payload: payload),
        );
        if (consumed) return;
      }
      final text = _tryDecodeUtf8(raw);
      if (text != null) {
        _handleTextFrame(text);
      } else {
        _binaryController.add(raw);
      }
    }
  }

  String? _tryDecodeUtf8(List<int> raw) {
    try {
      return utf8.decode(raw);
    } catch (_) {
      return null;
    }
  }

  void _handleTextFrame(String raw) {
    Map<String, dynamic> frameMap;
    try {
      frameMap = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return;
    }

    final op = frameMap['op'];

    final textHandler = onTextFrame;
    if (textHandler != null && textHandler(frameMap)) {
      return;
    }

    if (op == 'hello') {
      final payload = frameMap['payload'];
      if (payload is Map<String, dynamic>) {
        final supports = payload['supports'];
        if (supports is List) {
          peerSupports = supports.whereType<String>().toList();
        }
      }
      final completer = _helloCompleter;
      if (completer != null && !completer.isCompleted) {
        completer.complete();
      }
      return;
    }

    final id = frameMap['id'];
    if (id is String && _pendingRequests.containsKey(id)) {
      if (op == 'error') {
        final payload = frameMap['payload'];
        final message = payload is Map ? payload['error'] : 'WebSocket error';
        _pendingRequests[id]!.completeError(
          StateError(message?.toString() ?? 'WebSocket error'),
        );
      } else {
        final payload = frameMap['payload'];
        _pendingRequests[id]!.complete(
          payload is Map<String, dynamic> ? payload : <String, dynamic>{},
        );
      }
      return;
    }

    if (op == 'pong') return;

    WsFrame frame;
    try {
      frame = WsFrame.decode(raw);
    } catch (_) {
      _incomingController.add(frameMap);
      return;
    }

    if (_frameRouter.isPeerRequest(frame)) {
      unawaited(_respondToLocalRequest(frame));
      return;
    }

    _incomingController.add(frameMap);
  }

  Future<void> _respondToLocalRequest(WsFrame frame) async {
    try {
      Logging.debug(
        'inbound request op=${frame.op} from $peerOnion',
        'TorWebSocketClient',
      );
      final responses = await _frameRouter.handleInboundFrame(
        frame,
        peerOnion: peerOnion,
      );
      final socket = _socket;
      if (socket == null) return;
      for (final encoded in responses) {
        socket.add(encoded);
      }
    } catch (e, stack) {
      Logging.error(
        'inbound request failed op=${frame.op}: $e\n$stack',
        'TorWebSocketClient',
      );
      final requestId = frame.id;
      if (requestId != null && _socket != null) {
        _socket!.add(
          WsFrame.error(id: requestId, message: 'Processing failed').encode(),
        );
      }
    }
  }

  void _onDone() {
    if (_disconnecting) return;
    unawaited(disconnect());
  }

  void _onError(Object error) {
    if (_disconnecting) return;
    unawaited(disconnect());
  }

  void _failPendingRequests(Object error) {
    for (final completer in _pendingRequests.values) {
      if (!completer.isCompleted) {
        completer.completeError(error);
      }
    }
    _pendingRequests.clear();
    final hello = _helloCompleter;
    if (hello != null && !hello.isCompleted) {
      hello.completeError(error);
    }
    _helloCompleter = null;
  }

  Future<void> disconnect() async {
    if (_disconnecting) return;
    _disconnecting = true;
    try {
      _handshakeComplete = false;

      final sub = _subscription;
      _subscription = null;
      await sub?.cancel();

      _failPendingRequests(StateError('WebSocket disconnected'));

      final socket = _socket;
      _socket = null;
      if (socket != null) {
        try {
          await socket.close();
        } catch (e) {
            Logging.error('TorWebSocketClient: socket close failed: $e', 'TorWebSocketClient');          
        }
      }
    } finally {
      _disconnecting = false;
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    await disconnect();
    await _incomingController.close();
    await _binaryController.close();
  }
}
