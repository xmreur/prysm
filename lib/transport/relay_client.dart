import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:prysm/client/TorHttpClient.dart';
import 'package:prysm/transport/transport_provider.dart';
import 'package:prysm/util/tor_delivery.dart';
import 'package:prysm_relay_protocol/prysm_relay_protocol.dart';

/// What an owner needs to authenticate a relay request: who the relay is, who
/// the owner is, and the key that proves it.
class RelayAuth {
  final String relayFingerprint;
  final String ownerFingerprint;
  final KeyPair signKeyPair;

  const RelayAuth({
    required this.relayFingerprint,
    required this.ownerFingerprint,
    required this.signKeyPair,
  });
}

/// Speaks `prysm-relay/1` to one relay over Tor.
///
/// Reuses [TorHttpClient] and [TorDelivery], so relays inherit the SOCKS
/// plumbing, the retry policy and the circuit handling the app already has: a
/// relay onion is just another onion.
class RelayClient {
  RelayClient({required this.relayOnion, int? socksPort})
      : socksPort = socksPort ?? TransportProvider.socksPortOrDefault;

  final String relayOnion;
  final int socksPort;

  static const Duration defaultTimeout = Duration(seconds: 30);

  /// Public: no Contract needed, which is the point — the user reads the
  /// manifest *before* agreeing to anything.
  Future<RelayManifest> manifest({Duration timeout = defaultTimeout}) async {
    final json = await _send(
      'GET',
      RelayProtocol.pathManifest,
      null,
      timeout: timeout,
      maxAttempts: 2,
    );
    return RelayManifest.fromJson(json);
  }

  Future<RelayContract> pair(
    RelayPairRequest request, {
    Duration timeout = defaultTimeout,
  }) async {
    final json = await _send(
      'POST',
      RelayProtocol.pathPair,
      request.toJson(),
      timeout: timeout,
      maxAttempts: 2,
    );
    return RelayContract.fromJson(json);
  }

  /// Authorised by knowing [deposit] alone: the sender never identifies itself.
  ///
  /// One attempt only. A relay that cannot take the message right now must not
  /// hold up the send path; the message is already safe in the local queue.
  Future<RelayDepositResponse> deposit({
    required String deposit,
    required Map<String, dynamic> payload,
    Duration timeout = defaultTimeout,
  }) async {
    final json = await _send(
      'POST',
      RelayProtocol.pathDeposit,
      RelayDepositRequest(deposit: deposit, payload: payload).toJson(),
      timeout: timeout,
      maxAttempts: 1,
    );
    return RelayDepositResponse.fromJson(json);
  }

  /// Signs [body] and posts it to an owner-authenticated endpoint.
  ///
  /// The signature covers the exact bytes that go on the wire, so the encoded
  /// body is reused verbatim instead of being re-encoded.
  Future<Map<String, dynamic>> authed(
    String path,
    Map<String, dynamic> body, {
    required RelayAuth auth,
    Duration timeout = defaultTimeout,
    int maxAttempts = 2,
  }) async {
    final encoded = jsonEncode(body);
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final signature = await RelaySigning.sign(
      RelaySigning.authBytes(
        relayFingerprint: auth.relayFingerprint,
        ownerFingerprint: auth.ownerFingerprint,
        method: 'POST',
        path: path,
        timestampMs: timestamp,
        bodySha256Hex: RelaySigning.sha256Hex(utf8.encode(encoded)),
      ),
      auth.signKeyPair,
    );
    return _send(
      'POST',
      path,
      body,
      preEncodedBody: encoded,
      headers: {
        RelayProtocol.headerOwner: auth.ownerFingerprint,
        RelayProtocol.headerTimestamp: '$timestamp',
        RelayProtocol.headerSignature: signature,
      },
      timeout: timeout,
      maxAttempts: maxAttempts,
    );
  }

  Future<Map<String, dynamic>> _send(
    String method,
    String path,
    Map<String, dynamic>? body, {
    Map<String, String>? headers,
    String? preEncodedBody,
    Duration timeout = defaultTimeout,
    int maxAttempts = 1,
  }) {
    final uri = Uri.parse('http://$relayOnion:80$path');
    return TorDelivery.withTorRetry<Map<String, dynamic>>(
      maxAttempts: maxAttempts,
      // A typed protocol answer is the relay talking, not the network failing:
      // only its own retryable codes earn another attempt.
      isRetryable: (error) => error is RelayError
          ? error.retryable
          : TorDelivery.isRetryableError(error),
      attempt: () async {
        final client = TorHttpClient(
          proxyHost: '127.0.0.1',
          proxyPort: socksPort,
        );
        try {
          final requestHeaders = <String, String>{
            'Content-Type': 'application/json',
            ...?headers,
          };
          // One deadline for the whole exchange. The body read used to sit
          // outside the timeout, so a relay that answered its headers and
          // then stalled held the caller forever — and `pickupNow` runs
          // inside `flushAllPending`, which would never finish either.
          Future<Map<String, dynamic>> exchange() async {
            final HttpClientResponse response;
            if (method == 'GET') {
              response = await client.get(uri, requestHeaders);
            } else {
              response = await client.post(
                uri,
                requestHeaders,
                preEncodedBody ?? jsonEncode(body ?? const {}),
              );
            }
            final text = await client.readUtf8Body(response);
            return decodeResponse(response.statusCode, text);
          }

          return await exchange().timeout(timeout);
        } finally {
          await client.close();
        }
      },
    );
  }

  /// Maps an HTTP answer onto the protocol's typed vocabulary. Exposed because
  /// the mapping is worth testing without a network.
  static Map<String, dynamic> decodeResponse(int status, String text) {
    Map<String, dynamic>? json;
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map) json = Map<String, dynamic>.from(decoded);
    } catch (_) {
      json = null;
    }
    if (status >= 200 && status < 300) {
      if (json == null) {
        throw const RelayError(
          RelayErrorCode.internal,
          'relay answered with a non-object body',
        );
      }
      return json;
    }
    if (json != null && json['error'] is String) {
      throw RelayError.fromJson(json);
    }
    throw RelayError(
      status >= 500 ? RelayErrorCode.internal : RelayErrorCode.badRequest,
      'relay answered HTTP $status',
    );
  }
}
