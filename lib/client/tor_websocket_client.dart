import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:prysm/client/tor_socks_websocket.dart';
import 'package:uuid/uuid.dart';
import 'package:prysm/transport/ws_protocol.dart';

/// Persistent WebSocket connection to a single peer over Tor SOCKS.
class TorWebSocketClient {
  TorWebSocketClient({
    required this.peerOnion,
    required this.socksPort,
    this.localOnion,
  });

  final String peerOnion;
  final int socksPort;
  final String? localOnion;

  WebSocket? _socket;
  StreamSubscription<dynamic>? _subscription;
  final Map<String, Completer<Map<String, dynamic>>> _pendingRequests = {};
  final _incomingController = StreamController<Map<String, dynamic>>.broadcast();
  bool _handshakeComplete = false;
  bool _disposed = false;
  bool _disconnecting = false;
  Completer<void>? _helloCompleter;

  Stream<Map<String, dynamic>> get onIncoming => _incomingController.stream;

  bool get isConnected =>
      !_disposed && _socket != null && _handshakeComplete;

  Future<void> connect({Duration timeout = const Duration(seconds: 30)}) async {
    if (_disposed) {
      throw StateError('TorWebSocketClient disposed');
    }

    try {
      final socket = await connectTorWebSocket(
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

  Future<void> sendPing() => send('ping');

  void _onMessage(dynamic raw) {
    if (raw is! String) return;

    Map<String, dynamic> frame;
    try {
      frame = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return;
    }

    final op = frame['op'];
    if (op == 'pong') return;

    if (op == 'hello') {
      final completer = _helloCompleter;
      if (completer != null && !completer.isCompleted) {
        completer.complete();
      }
      return;
    }

    final id = frame['id'];
    if (id is String && _pendingRequests.containsKey(id)) {
      if (op == 'error') {
        final payload = frame['payload'];
        final message = payload is Map ? payload['error'] : 'WebSocket error';
        _pendingRequests[id]!.completeError(
          StateError(message?.toString() ?? 'WebSocket error'),
        );
      } else {
        final payload = frame['payload'];
        _pendingRequests[id]!.complete(
          payload is Map<String, dynamic> ? payload : <String, dynamic>{},
        );
      }
      return;
    }

    if (op == 'ping') {
      _socket?.add(WsFrame.pong().encode());
      return;
    }

    _incomingController.add(frame);
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
        } catch (_) {}
      }
    } finally {
      _disconnecting = false;
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    await disconnect();
    await _incomingController.close();
  }
}
