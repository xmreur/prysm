import 'dart:async';
import 'dart:convert';

import 'package:prysm/services/call/call_signaling_notifier.dart';
import 'package:prysm/services/file_transfer_handler.dart';
import 'package:prysm/services/ws_connection_manager.dart';
import 'package:prysm/transport/ws_dial_policy.dart';
import 'package:prysm/transport/ws_frame_router.dart';
import 'package:prysm/transport/ws_peer_link.dart';
import 'package:prysm/transport/ws_protocol.dart';
import 'package:prysm/util/logging.dart';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Acceptor-side link over a peer's inbound [WebSocketChannel].
class InboundWsPeerLink implements WsPeerLink {
  InboundWsPeerLink._({
    required WebSocketChannel channel,
    required WsFrameRouter frameRouter,
    required String? Function() localOnion,
    WsConnectionManager? manager,
  })  : _channel = channel,
        _frameRouter = frameRouter,
        _localOnion = localOnion,
        _manager = manager;

  /// Accepts an inbound connection; owns the only [channel.stream] subscription.
  static void acceptIncoming({
    required WebSocketChannel channel,
    required WsFrameRouter frameRouter,
    required String? Function() localOnion,
    WsConnectionManager? manager,
  }) {
    final link = InboundWsPeerLink._(
      channel: channel,
      frameRouter: frameRouter,
      localOnion: localOnion,
      manager: manager,
    );
    link._subscription = channel.stream.listen(
      link._onRaw,
      onDone: link._handleDone,
      onError: (_) => unawaited(link.close()),
    );
  }

  @override
  String peerOnion = '';

  final WebSocketChannel _channel;
  final WsFrameRouter _frameRouter;
  final String? Function() _localOnion;
  final WsConnectionManager? _manager;

  final Map<String, Completer<Map<String, dynamic>>> _pendingRequests = {};
  final _pushController = StreamController<Map<String, dynamic>>.broadcast();
  final _binaryController = StreamController<List<int>>.broadcast();
  StreamSubscription<dynamic>? _subscription;
  bool _handshakeComplete = false;
  bool _closed = false;
  List<String> peerSupports = const [];

  @override
  bool get isConnected => !_closed && _handshakeComplete && peerOnion.isNotEmpty;

  @override
  Stream<Map<String, dynamic>> get onPushFrames => _pushController.stream;

  @override
  Stream<List<int>> get onBinaryFrames => _binaryController.stream;

  @override
  Future<void> send(String op, {Map<String, dynamic>? payload}) async {
    if (!isConnected) {
      throw StateError('WebSocket not connected to $peerOnion');
    }
    _channel.sink.add(WsFrame(op: op, payload: payload).encode());
  }

  @override
  Future<Map<String, dynamic>> request(
    String op, {
    Map<String, dynamic>? payload,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (!isConnected) {
      throw StateError('WebSocket not connected to $peerOnion');
    }

    final id = const Uuid().v4();
    final completer = Completer<Map<String, dynamic>>();
    _pendingRequests[id] = completer;

    final encoded = WsFrame(op: op, id: id, payload: payload).encode();
    Logging.debug(
      'request op=$op id=$id bytes=${encoded.length} to $peerOnion',
      'InboundWsPeerLink',
    );
    _channel.sink.add(encoded);

    try {
      return await completer.future.timeout(timeout);
    } finally {
      _pendingRequests.remove(id);
    }
  }

  @override
  Future<void> sendPing() => send('ping');

  @override
  Future<void> sendBytes(List<int> bytes) async {
    if (!isConnected) {
      throw StateError('WebSocket not connected to $peerOnion');
    }
    _channel.sink.add(bytes);
  }

  Future<void> _onRaw(dynamic raw) async {
    if (_closed) return;

    if (raw is List<int>) {
      if (raw.isNotEmpty && raw[0] == callAudioFrameMagic) {
        if (_handshakeComplete) {
          _binaryController.add(raw);
        }
        return;
      }
      if (raw.isNotEmpty && raw[0] == fileTransferChunkMagic) {
        if (_handshakeComplete && peerOnion.isNotEmpty) {
          unawaited(
            FileTransferHandler.instance.handleBinaryChunk(
              raw,
              peerOnion: peerOnion,
              sendAck: (op, {payload}) => send(op, payload: payload),
            ),
          );
        }
        return;
      }
      final text = _decodeBytes(raw);
      if (text == null) {
        if (_handshakeComplete) {
          _binaryController.add(raw);
        }
        return;
      }
      await _handleText(text);
      return;
    }

    if (raw is String) {
      await _handleText(raw);
    }
  }

  Future<void> _handleText(String text) async {
    if (!_handshakeComplete) {
      await _handleHelloHandshake(text);
      return;
    }

    _dispatchPostHandshakeFrame(text);
  }

  Future<void> _handleHelloHandshake(String text) async {
    WsFrame frame;
    try {
      frame = WsFrame.decode(text);
    } catch (e) {
      Logging.error('invalid hello frame: $e', 'InboundWsPeerLink');
      await _rejectHandshake();
      return;
    }

    if (frame.op != 'hello') {
      _channel.sink.add(
        WsFrame.error(
          id: frame.id ?? 'handshake',
          message: 'hello required',
        ).encode(),
      );
      await _rejectHandshake();
      return;
    }

    final remoteOnion = frame.payload?['onion'] as String?;
    if (remoteOnion == null || remoteOnion.isEmpty) {
      await _rejectHandshake();
      return;
    }

    final local = _localOnion() ?? '';
    final manager = _manager;

    if (local.isNotEmpty && manager != null) {
      if (manager.hasLink(remoteOnion) || manager.isConnected(remoteOnion)) {
        await _rejectDuplicate(local);
        return;
      }

      if (shouldDialPeer(localOnion: local, peerOnion: remoteOnion)) {
        await _rejectDuplicate(local);
        return;
      }
    }

    peerOnion = remoteOnion;
    final supports = frame.payload?['supports'];
    if (supports is List) {
      peerSupports = supports.whereType<String>().toList();
    }
    _channel.sink.add(
      WsFrame.hello(onion: local.isNotEmpty ? local : null).encode(),
    );
    _handshakeComplete = true;
    manager?.registerInboundLink(this);

    Logging.debug('handshake complete from $peerOnion', 'InboundWsPeerLink');
    
  }

  Future<void> _rejectDuplicate(String localOnion) async {
    _channel.sink.add(WsFrame.hello(onion: localOnion).encode());
    _channel.sink.add(
      WsFrame.error(id: 'duplicate', message: 'duplicate connection').encode(),
    );
    await _rejectHandshake();
  }

  Future<void> rejectDuplicateConnection() async {
    if (_closed) return;
    try {
      final local = _localOnion() ?? '';
      _channel.sink.add(WsFrame.hello(onion: local.isNotEmpty ? local : null).encode());
      _channel.sink.add(
        WsFrame.error(id: 'duplicate', message: 'duplicate connection').encode(),
      );
    } catch (_) {}
    await close();
  }

  Future<void> _rejectHandshake() async {
    try {
      await _channel.sink.close();
    } catch (_) {}
    await close();
  }

  /// Fast path only — must not await heavy work so outbound acks are not delayed.
  void _dispatchPostHandshakeFrame(String text) {
    Map<String, dynamic> frameMap;
    try {
      frameMap = jsonDecode(text) as Map<String, dynamic>;
    } catch (_) {
      return;
    }

    final op = frameMap['op'];
    if (op is String && WsFrame.isCallOp(op)) {
      final payload = frameMap['payload'];
      if (payload is Map<String, dynamic> && peerOnion.isNotEmpty) {
        CallSignalingNotifier.active.applyInbound(peerOnion, op, payload);
      }
      return;
    }

    final id = frameMap['id'];
    if (id is String && _pendingRequests.containsKey(id)) {
      Logging.debug(
        'response op=$op id=$id peer=$peerOnion',
        'InboundWsPeerLink',
      );
      _completePendingRequest(id, frameMap);
      return;
    }

    if (op == 'pong') return;

    WsFrame frame;
    try {
      frame = WsFrame.decode(text);
    } catch (_) {
      return;
    }

    if (frame.op == 'ping') {
      final encoded = frame.id != null
          ? WsFrame(op: 'pong', id: frame.id).encode()
          : WsFrame.pong().encode();
      _channel.sink.add(encoded);
      return;
    }

    if (_frameRouter.isPeerRequest(frame)) {
      if (WsFrame.isFileTransferRequestOp(frame.op)) {
        Logging.debug(
          'inbound file-transfer op=${frame.op} from $peerOnion',
          'InboundWsPeerLink',
        );
      }
      unawaited(_handleInboundPeerRequest(frame));
      return;
    }

    if (op is String && WsFrame.isFileTransferOp(op)) {
      Logging.debug('push op=$op from $peerOnion', 'InboundWsPeerLink');
    }

    _pushController.add(frameMap);
  }

  void _completePendingRequest(String id, Map<String, dynamic> frameMap) {
    final completer = _pendingRequests[id];
    if (completer == null || completer.isCompleted) return;

    final op = frameMap['op'];
    if (op == 'error') {
      final payload = frameMap['payload'];
      final message = payload is Map ? payload['error'] : 'WebSocket error';
      completer.completeError(
        StateError(message?.toString() ?? 'WebSocket error'),
      );
      return;
    }

    final payload = frameMap['payload'];
    completer.complete(
      payload is Map<String, dynamic> ? payload : <String, dynamic>{},
    );
  }

  Future<void> _handleInboundPeerRequest(WsFrame frame) async {
    try {
      final responses =
          await _frameRouter.handleInboundFrame(frame, peerOnion: peerOnion);
      if (_closed) return;
      Logging.debug(
        'answered op=${frame.op} id=${frame.id} frames=${responses.length} '
        'peer=$peerOnion',
        'InboundWsPeerLink',
      );
      for (final encoded in responses) {
        _channel.sink.add(encoded);
      }
    } catch (e, stack) {
      Logging.error('inbound request error: $e\n$stack', 'InboundWsPeerLink');
      final requestId = frame.id;
      if (requestId != null && !_closed) {
        _channel.sink.add(
          WsFrame.error(id: requestId, message: 'Processing failed').encode(),
        );
      }
    }
  }

  String? _decodeBytes(List<int> raw) {
    try {
      return utf8.decode(raw);
    } catch (_) {
      return null;
    }
  }

  void _handleDone() {
    if (_closed) return;
    unawaited(close());
  }

  void _failPending(Object error) {
    for (final completer in _pendingRequests.values) {
      if (!completer.isCompleted) {
        completer.completeError(error);
      }
    }
    _pendingRequests.clear();
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _handshakeComplete = false;

    await _subscription?.cancel();
    _subscription = null;

    _failPending(StateError('WebSocket disconnected'));

    try {
      await _channel.sink.close();
    } catch (_) {}

    if (peerOnion.isNotEmpty) {
      _manager?.unregisterLink(peerOnion);
    }

    if (!_pushController.isClosed) {
      await _pushController.close();
    }
    if (!_binaryController.isClosed) {
      await _binaryController.close();
    }
  }
}
