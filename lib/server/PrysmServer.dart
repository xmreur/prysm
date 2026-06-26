import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:prysm/client/TorHttpClient.dart';
import 'package:prysm/server/inbound_message_router.dart';
import 'package:prysm/transport/transport_provider.dart';
import 'package:prysm/transport/ws_protocol.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/peer_profile_cache.dart';
import 'package:prysm/util/tor_delivery.dart';
import 'package:prysm/services/settings_service.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class PrysmServer {
  static PrysmServer? instance;

  final int port;
  final KeyManager keyManager;
  HttpServer? _server;

  final settings = SettingsService();
  late final InboundMessageRouter _router;

  InboundMessageRouter get inboundRouter => _router;

  /// Set when Tor is ready so group control messages can be processed.
  String? localOnionAddress;

  PrysmServer({this.port = 8080, required this.keyManager}) {
    instance = this;
    _router = InboundMessageRouter(
      keyManager: keyManager,
      settings: settings,
      localOnionAddress: () => localOnionAddress,
      fetchSenderProfile: _fetchSenderProfile,
    );
  }

  Future<void> start() async {
    final handler = Pipeline()
        .addMiddleware(logRequests())
        .addHandler(_rootHandler);

    _server = await io.serve(
      handler,
      InternetAddress.anyIPv4,
      port,
      shared: true,
    );

    print('HTTP server now running on http://127.0.0.1:$port');
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    print('HTTP server stopped');
  }

  FutureOr<Response> _rootHandler(Request request) {
    if (request.method == 'GET' && request.url.path == 'ws') {
      return webSocketHandler(_handleWebSocket)(request);
    }
    return _requestHandler(request);
  }

  Future<Response> _requestHandler(Request request) async {
    print('${request.method} - ${request.url}');

    try {
      if (request.method == 'POST' && request.url.path == 'message') {
        return await _handlePostMessage(request);
      }

      if (request.method == 'GET' && request.url.path == 'public') {
        return _toResponse(_router.buildPublicKey());
      }

      if (request.method == 'GET' && request.url.path == 'profile') {
        return _toResponse(_router.buildProfile());
      }

      if (request.method == 'POST' && request.url.path == 'sync-hint') {
        return await _handlePostSyncHint(request);
      }

      return Response.notFound(
        jsonEncode({'error': 'Endpoint not found'}),
        headers: {'Content-Type': 'application/json'},
      );
    } catch (e, stack) {
      print('PrysmServer Error: $e\n$stack');
      return Response.internalServerError(
        body: jsonEncode({'error': 'Internal server error'}),
      );
    }
  }

  Future<Map<String, dynamic>> _readJsonBody(Request request) async {
    final bodyBytes = await request.read().expand((chunk) => chunk).toList();
    if (bodyBytes.isEmpty) {
      throw const FormatException('Empty request body');
    }

    late final String payload;
    try {
      payload = utf8.decode(bodyBytes);
    } on FormatException catch (e) {
      print(
        'PrysmServer: invalid UTF-8 request body (${bodyBytes.length} bytes): $e',
      );
      rethrow;
    }

    final decoded = jsonDecode(payload);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('JSON body must be an object');
    }
    return decoded;
  }

  Future<Response> _handlePostMessage(Request request) async {
    try {
      final data = await _readJsonBody(request);
      final result = await _router.handleMessage(data);
      return _toResponse(result);
    } on FormatException catch (e, stack) {
      print('PrysmServer POST /message invalid body: $e\n$stack');
      return _badRequest('Invalid message body');
    } catch (e, stack) {
      print('PrysmServer POST /message Error $e\n$stack');
      return Response.internalServerError(
        body: jsonEncode({'error': 'Processing failed'}),
        headers: {'Content-Type': 'application/json'},
      );
    }
  }

  Future<Response> _handlePostSyncHint(Request request) async {
    try {
      final data = await _readJsonBody(request);
      final result = await _router.handleSyncHint(data);
      return _toResponse(result);
    } on FormatException catch (e, stack) {
      print('PrysmServer POST /sync-hint invalid body: $e\n$stack');
      return _badRequest('Invalid sync-hint body');
    } catch (e, stack) {
      print('PrysmServer POST /sync-hint Error $e\n$stack');
      return Response.internalServerError(
        body: jsonEncode({'error': 'Processing failed'}),
        headers: {'Content-Type': 'application/json'},
      );
    }
  }

  void _handleWebSocket(WebSocketChannel channel) {
    var helloReceived = false;

    channel.stream.listen(
      (raw) async {
        try {
          await _handleWebSocketFrame(
            channel,
            raw,
            helloReceived: helloReceived,
            onHello: () => helloReceived = true,
          );
        } catch (e, stack) {
          debugPrint('PrysmServer WS frame error: $e\n$stack');
        }
      },
      onError: (Object e) => debugPrint('PrysmServer WS stream error: $e'),
      onDone: () {
        if (helloReceived) {
          debugPrint('PrysmServer WS disconnected');
        }
      },
    );
  }

  Future<void> _handleWebSocketFrame(
    WebSocketChannel channel,
    dynamic raw, {
    required bool helloReceived,
    required void Function() onHello,
  }) async {
    if (raw is! String) return;

    WsFrame frame;
    try {
      frame = WsFrame.decode(raw);
    } catch (e) {
      debugPrint('PrysmServer WS invalid frame: $e');
      return;
    }

    if (frame.op == 'hello') {
      onHello();
      channel.sink.add(WsFrame.hello().encode());
      return;
    }

    if (!helloReceived && frame.op != 'ping') {
      channel.sink.add(
        WsFrame.error(id: frame.id ?? 'handshake', message: 'hello required')
            .encode(),
      );
      return;
    }

    if (frame.op == 'ping') {
      channel.sink.add(WsFrame.pong().encode());
      return;
    }

    if (frame.op == 'get_profile') {
      final result = _router.buildProfile();
      channel.sink.add(
        WsFrame.response(
          op: 'profile',
          id: frame.id ?? '',
          payload: result.jsonBody,
        ).encode(),
      );
      return;
    }

    if (frame.op == 'get_public') {
      final result = _router.buildPublicKey();
      channel.sink.add(
        WsFrame.response(
          op: 'public',
          id: frame.id ?? '',
          payload: {'publicKeyPem': result.plainTextBody ?? ''},
        ).encode(),
      );
      return;
    }

    if (frame.op == 'message' || WsFrame.isInboundSideChannelOp(frame.op)) {
      final payload = frame.payload;
      if (payload == null) return;
      print(
        'PrysmServer WS ${frame.op} from ${payload['senderId']} '
        'type=${payload['type']}',
      );
      try {
        final result = await _router.handleMessage(payload);
        if (frame.id != null) {
          final ackOp =
              frame.op == 'message' ? 'message_ack' : '${frame.op}_ack';
          channel.sink.add(
            WsFrame.response(
              op: ackOp,
              id: frame.id!,
              payload: result.jsonBody,
            ).encode(),
          );
        }
      } catch (e, stack) {
        debugPrint('PrysmServer WS ${frame.op} error: $e\n$stack');
        if (frame.id != null) {
          channel.sink.add(
            WsFrame.error(id: frame.id!, message: 'Processing failed')
                .encode(),
          );
        }
      }
      return;
    }

    if (frame.op == 'sync-hint') {
      final payload = frame.payload;
      if (payload == null) return;
      try {
        final result = await _router.handleSyncHint(payload);
        if (frame.id != null) {
          channel.sink.add(
            WsFrame.response(
              op: 'sync-hint_ack',
              id: frame.id!,
              payload: result.jsonBody,
            ).encode(),
          );
        }
      } catch (e, stack) {
        debugPrint('PrysmServer WS sync-hint error: $e\n$stack');
        if (frame.id != null) {
          channel.sink.add(
            WsFrame.error(id: frame.id!, message: 'Processing failed')
                .encode(),
          );
        }
      }
    }
  }

  Response _toResponse(InboundHandleResult result) {
    if (result.plainTextBody != null) {
      return Response(
        result.statusCode,
        body: result.plainTextBody,
        headers: {'Content-Type': 'text/plain'},
      );
    }
    return Response(
      result.statusCode,
      body: jsonEncode(result.jsonBody ?? {}),
      headers: {'Content-Type': 'application/json'},
    );
  }

  void _fetchSenderProfile(String senderId) {
    if (!PeerProfileCache.instance.shouldFetch(senderId)) return;

    Zone.current.fork(
      specification: ZoneSpecification(
        handleUncaughtError: (self, parent, zone, error, stackTrace) {
          print('Suppressed error in _fetchSenderProfile: $error');
        },
      ),
    ).run(() async {
      try {
        final body = TransportProvider.isConfigured
            ? await TransportProvider.instance.getProfile(senderId)
            : await TorDelivery.withTorRetry<String>(
                attempt: () async {
                  final torClient = TorHttpClient(
                    proxyHost: '127.0.0.1',
                    proxyPort: 9050,
                  );
                  try {
                    final uri = Uri.parse('http://$senderId:80/profile');
                    final response = await torClient
                        .get(uri, {})
                        .timeout(const Duration(seconds: 20));
                    return torClient.readUtf8Body(response);
                  } finally {
                    torClient.close();
                  }
                },
              );
        final data = jsonDecode(body) as Map<String, dynamic>;

        final updates = <String, dynamic>{};
        if (data['publicKeyPem'] != null &&
            (data['publicKeyPem'] as String).isNotEmpty) {
          updates['publicKeyPem'] = data['publicKeyPem'];
        }
        if (data['username'] != null &&
            (data['username'] as String).isNotEmpty) {
          updates['name'] = data['username'];
        }
        if (data['avatar'] != null && (data['avatar'] as String).isNotEmpty) {
          updates['avatarBase64'] = data['avatar'];
        }
        if (updates.isNotEmpty) {
          await DBHelper.updateUserFields(senderId, updates);
        }
        PeerProfileCache.instance.markFetched(senderId);
      } catch (e) {
        print('Failed to fetch sender profile: $e');
      }
    });
  }

  Response _badRequest(String message) {
    return Response(
      400,
      body: jsonEncode({'error': message}),
      headers: {'Content-Type': 'application/json'},
    );
  }
}
