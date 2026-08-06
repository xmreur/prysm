import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:prysm/client/TorHttpClient.dart';
import 'package:prysm/crypto/identity.dart';
import 'package:prysm/server/inbound_limits.dart';
import 'package:prysm/server/inbound_message_router.dart';
import 'package:prysm/server/inbound_rate_limiter.dart';
import 'package:prysm/transport/inbound_ws_peer_link.dart';
import 'package:prysm/transport/transport_preference.dart';
import 'package:prysm/transport/transport_provider.dart';
import 'package:prysm/transport/ws_frame_router.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/logging.dart';
import 'package:prysm/util/peer_profile_cache.dart';
import 'package:prysm/util/peer_identity_loader.dart';
import 'package:prysm/util/profile_http_uri.dart';
import 'package:prysm/util/tor_delivery.dart';
import 'package:prysm/services/block_service.dart';
import 'package:prysm/services/peer_identity_resolver.dart';
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
  final WsFrameRouter _frameRouter = WsFrameRouter();

  InboundRateLimiter _rateLimiter = InboundRateLimiter();

  /// Shared byte budget for all in-flight request bodies, so concurrent
  /// slow-drip bodies cannot accumulate past [InboundLimits.maxInFlightBodyBytes]
  /// even though each individual body is within its per-body cap.
  InboundBodyBudget _bodyBudget = InboundBodyBudget();

  /// Namespace prefix for wire-derived rate-limit keys: [InboundRateLimiter]
  /// reserves `'*'` ([InboundRateLimiter.globalKey]) as the global-only probe
  /// that never consumes a per-key window, so a wire-supplied `senderId` /
  /// `requester` of `'*'` must not be allowed to hit that reserved key.
  static const String _wireRateKeyPrefix = 's:';

  @visibleForTesting
  set rateLimiterOverride(InboundRateLimiter limiter) => _rateLimiter = limiter;

  @visibleForTesting
  set bodyBudgetOverride(InboundBodyBudget budget) => _bodyBudget = budget;

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
      resolvePeerIdentity: _resolvePeerIdentityForIngress,
    );
  }

  Future<IdentityPublicKeys?> _resolvePeerIdentityForIngress(
    String senderId,
  ) async {
    final resolver = PeerIdentityResolver(
      peerId: senderId,
      keyManager: keyManager,
    );
    return resolvePeerIdentityForIngress(
      keyManager,
      senderId,
      fetchOverTor: () => resolver.fetchOverTor(),
    );
  }

  Future<void> start() async {
    if (_server != null) return;

    // The shelf access line carries the full requested URI (path + query),
    // so a peer-supplied ?requester= would reach stdout unredacted with the
    // default print() logger, in release builds too. Routing it through
    // Logging applies the central onion scrub to every sink.
    final handler = Pipeline()
        .addMiddleware(logRequests(logger: (message, isError) => isError
            ? Logging.error(message, 'PrysmServer')
            : Logging.info(message, 'PrysmServer')))
        .addHandler(_rootHandler);

    _server = await io.serve(
      handler,
      InternetAddress.loopbackIPv4,
      port,
      shared: true,
    );

    Logging.info('HTTP server now running on http://127.0.0.1:$port', 'PrysmServer');
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    Logging.info('HTTP server stopped', 'PrysmServer');
  }

  FutureOr<Response> _rootHandler(Request request) {
    if (request.method == 'GET' && request.url.path == 'ws') {
      // WebSocket upgrades must pass the same global gate as every other
      // endpoint: without this, unauthenticated hello floods would skip the
      // rate limiter entirely, each still costing an sqlite identity lookup.
      if (!_rateLimiter.allow(InboundRateLimiter.globalKey)) {
        return _rateLimited();
      }
      return webSocketHandler(_handleWebSocket)(request);
    }
    return _requestHandler(request);
  }

  Future<Response> _requestHandler(Request request) async {
    final url = request.url;
    final requester = url.queryParameters['requester'];
    final logUrl = (requester != null && requester.isNotEmpty)
        ? url.replace(queryParameters: {
            ...url.queryParameters,
            'requester': Logging.redactOnion(requester),
          })
        : url;
    Logging.info('${request.method} - $logUrl', 'PrysmServer');

    try {
      if (!_rateLimiter.allow(InboundRateLimiter.globalKey)) {
        return _rateLimited();
      }

      if (request.method == 'POST' && request.url.path == 'message') {
        return await _handlePostMessage(request);
      }

      if (request.method == 'GET' && request.url.path == 'public') {
        return _toResponse(await _router.buildPublicKey());
      }

      if (request.method == 'GET' && request.url.path == 'profile') {
        final requester = request.url.queryParameters['requester'];
        if (requester is String &&
            requester.isNotEmpty &&
            !_rateLimiter.allow('$_wireRateKeyPrefix$requester')) {
          return _rateLimited();
        }
        return _toResponse(
          await _router.buildProfile(
            requesterOnion: requester,
            requireRequester: true,
          ),
        );
      }

      if (request.method == 'POST' && request.url.path == 'sync-hint') {
        return await _handlePostSyncHint(request);
      }

      return Response.notFound(
        jsonEncode({'error': 'Endpoint not found'}),
        headers: {'Content-Type': 'application/json'},
      );
    } catch (e, stack) {
      Logging.error('PrysmServer Error: $e\n$stack', 'PrysmServer');
      return Response.internalServerError(
        body: jsonEncode({'error': 'Internal server error'}),
      );
    }
  }

  Future<Map<String, dynamic>> _readJsonBody(
    Request request, {
    required int maxBytes,
    InboundBodyBudget? budget,
  }) async {
    final bodyBytes = await InboundLimits.readCapped(
      request.read(),
      maxBytes,
      budget: budget,
    );
    if (bodyBytes.isEmpty) {
      throw const FormatException('Empty request body');
    }

    late final String payload;
    try {
      payload = utf8.decode(bodyBytes);
    } on FormatException catch (e) {
      Logging.error('PrysmServer: invalid UTF-8 request body (${bodyBytes.length} bytes): $e', 'PrysmServer');
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
      final data = await _readJsonBody(
        request,
        maxBytes: InboundLimits.maxMessageBodyBytes,
        budget: _bodyBudget,
      );
      final senderId = data['senderId'];
      if (senderId is String &&
          senderId.isNotEmpty &&
          !_rateLimiter.allow('$_wireRateKeyPrefix$senderId')) {
        return _rateLimited();
      }
      final result = await _router.handleMessage(data);
      return _toResponse(result);
    } on ServerBusyException catch (e, stack) {
      Logging.error(
        'PrysmServer POST /message in-flight budget exhausted: $e\n$stack',
        'PrysmServer',
      );
      // 503, deliberately not 413: the message may be perfectly sized; the
      // server as a whole is busy holding other bodies right now.
      return Response(
        503,
        body: jsonEncode({'error': 'Server busy'}),
        headers: {'Content-Type': 'application/json'},
      );
    } on PayloadTooLargeException catch (e, stack) {
      Logging.error(
        'PrysmServer POST /message body too large: $e\n$stack',
        'PrysmServer',
      );
      return Response(
        413,
        body: jsonEncode({'error': 'Request body too large'}),
        headers: {'Content-Type': 'application/json'},
      );
    } on FormatException catch (e, stack) {
      Logging.error('PrysmServer POST /message invalid body: $e\n$stack', 'PrysmServer');
      return _badRequest('Invalid message body');
    } catch (e, stack) {
      Logging.error('PrysmServer POST /message Error $e\n$stack', 'PrysmServer');
      return Response.internalServerError(
        body: jsonEncode({'error': 'Processing failed'}),
        headers: {'Content-Type': 'application/json'},
      );
    }
  }

  Future<Response> _handlePostSyncHint(Request request) async {
    try {
      final data = await _readJsonBody(
        request,
        maxBytes: InboundLimits.maxControlBodyBytes,
        budget: _bodyBudget,
      );
      final senderId = data['senderId'];
      if (senderId is String &&
          senderId.isNotEmpty &&
          !_rateLimiter.allow('$_wireRateKeyPrefix$senderId')) {
        return _rateLimited();
      }
      final result = await _router.handleSyncHint(data);
      return _toResponse(result);
    } on ServerBusyException catch (e, stack) {
      Logging.error(
        'PrysmServer POST /sync-hint in-flight budget exhausted: $e\n$stack',
        'PrysmServer',
      );
      return Response(
        503,
        body: jsonEncode({'error': 'Server busy'}),
        headers: {'Content-Type': 'application/json'},
      );
    } on PayloadTooLargeException catch (e, stack) {
      Logging.error(
        'PrysmServer POST /sync-hint body too large: $e\n$stack',
        'PrysmServer',
      );
      return Response(
        413,
        body: jsonEncode({'error': 'Request body too large'}),
        headers: {'Content-Type': 'application/json'},
      );
    } on FormatException catch (e, stack) {
      Logging.error('PrysmServer POST /sync-hint invalid body: $e\n$stack', 'PrysmServer');
      return _badRequest('Invalid sync-hint body');
    } catch (e, stack) {
      Logging.error('PrysmServer POST /sync-hint Error $e\n$stack', 'PrysmServer');
      return Response.internalServerError(
        body: jsonEncode({'error': 'Processing failed'}),
        headers: {'Content-Type': 'application/json'},
      );
    }
  }

  void _handleWebSocket(WebSocketChannel channel) {
    InboundWsPeerLink.acceptIncoming(
      channel: channel,
      frameRouter: _frameRouter,
      localOnion: () => localOnionAddress,
      // Cache-only on purpose: the handshake verifies the claimed identity
      // before any state-dependent reply, so resolution must never trigger a
      // Tor fetch that an unauthenticated flood could force. First contact
      // with an unknown peer already goes over HTTP (ContactAddService uses
      // TransportPreference.httpOnly), and handleSyncHint gates on a known
      // contact too.
      resolvePeerIdentity: (peerId) => loadPeerIdentityFromDb(keyManager, peerId),
      manager: TransportProvider.isConfigured
          ? TransportProvider.instance.wsManager
          : null,
    );
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
    if (BlockService.instance.isBlocked(senderId)) return;
    if (!PeerProfileCache.instance.shouldFetch(senderId)) return;

    Zone.current.fork(
      specification: ZoneSpecification(
        handleUncaughtError: (self, parent, zone, error, stackTrace) {
          Logging.error('Suppressed error in _fetchSenderProfile: $error', 'PrysmServer');
        },
      ),
    ).run(() async {
      try {
        final body = TransportProvider.isConfigured
            ? await TransportProvider.instance.getProfileWithPreference(
                senderId,
                preference: TransportPreference.wsPreferred,
              )
            : await TorDelivery.withTorRetry<String>(
                attempt: () async {
                  final torClient = TorHttpClient(
                    proxyHost: '127.0.0.1',
                    proxyPort: 9050,
                  );
                  try {
                    final requester = localOnionAddress;
                    final uri = ProfileHttpUri.build(
                      senderId,
                      requesterOnion: requester,
                    );
                    final response = await torClient
                        .get(uri, {})
                        .timeout(const Duration(seconds: 20));
                    return torClient.readUtf8Body(response);
                  } finally {
                    await torClient.close();
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
        Logging.error('Failed to fetch sender profile: $e', 'PrysmServer');
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

  Response _rateLimited() {
    return Response(
      429,
      body: jsonEncode({'error': 'Rate limited'}),
      headers: {'Content-Type': 'application/json'},
    );
  }
}
