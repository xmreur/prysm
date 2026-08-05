import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:socks5_proxy/socks_client.dart';

/// Builds the HTTP/1.1 WebSocket upgrade request for a Tor hidden service.
String buildWebSocketUpgradeRequest({
  required String host,
  required String path,
  required String secWebSocketKey,
}) {
  return 'GET $path HTTP/1.1\r\n'
      'Host: $host\r\n'
      'Upgrade: websocket\r\n'
      'Connection: Upgrade\r\n'
      'Sec-WebSocket-Key: $secWebSocketKey\r\n'
      'Sec-WebSocket-Version: 13\r\n\r\n';
}

/// RFC 6455 §4.1 magic GUID appended to the client key before hashing.
const String _webSocketGuid = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

/// Returns the `Sec-WebSocket-Accept` value a server must echo for
/// [secWebSocketKey]: `base64(sha1(<client-key> + GUID))` (RFC 6455 §4.1).
String computeWebSocketAccept(String secWebSocketKey) {
  final digest = sha1.convert(utf8.encode('$secWebSocketKey$_webSocketGuid'));
  return base64.encode(digest.bytes);
}

/// Returns true when [headers] are a 101 Switching Protocols response whose
/// `Sec-WebSocket-Accept` matches the accept derived from
/// [secWebSocketKey] — the key that was actually sent in the upgrade
/// request.
///
/// The status line alone is not trusted: a hostile or broken server could
/// answer 101 to anything. RFC 6455 §4.1 requires the server to prove it
/// processed the handshake by echoing `base64(sha1(key + GUID))`; a missing
/// or mismatched `Sec-WebSocket-Accept` header means the upgrade is refused.
bool isWebSocketUpgradeResponse(
  String headers, {
  required String secWebSocketKey,
}) {
  final lines = headers.split('\r\n');
  if (!lines.first.trim().contains('101')) return false;

  for (final line in lines.skip(1)) {
    final colon = line.indexOf(':');
    if (colon <= 0) continue;
    final name = line.substring(0, colon).trim().toLowerCase();
    if (name != 'sec-websocket-accept') continue;
    final value = line.substring(colon + 1).trim();
    return value == computeWebSocketAccept(secWebSocketKey);
  }
  return false;
}

/// Generates a RFC 6455 Sec-WebSocket-Key value.
String generateSecWebSocketKey([Random? random]) {
  final rng = random ?? Random.secure();
  final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
  return base64.encode(bytes);
}

Future<List<int>> readUntilHeaderEnd(
  Stream<List<int>> stream, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final buffer = <int>[];
  var matched = 0;

  await for (final chunk in stream.timeout(timeout)) {
    for (final byte in chunk) {
      buffer.add(byte);
      switch (matched) {
        case 0:
          matched = byte == 13 ? 1 : 0;
        case 1:
          matched = byte == 10 ? 2 : (byte == 13 ? 1 : 0);
        case 2:
          matched = byte == 13 ? 3 : (byte == 13 ? 1 : 0);
        case 3:
          if (byte == 10) {
            return buffer;
          }
          matched = byte == 13 ? 1 : 0;
      }
    }
  }

  throw TimeoutException('Timed out waiting for HTTP response headers', timeout);
}

/// Opens a WebSocket to [peerOnion]:80/ws via Tor SOCKS proxy.
Future<WebSocket> connectTorWebSocket({
  required String peerOnion,
  required int socksPort,
  Duration timeout = const Duration(seconds: 30),
}) async {
  final proxies = [ProxySettings(InternetAddress('127.0.0.1'), socksPort)];
  final host = InternetAddress(peerOnion, type: InternetAddressType.unix);

  Socket? socksSocket;
  try {
    socksSocket = await SocksTCPClient.connect(proxies, host, 80)
        .timeout(timeout);

    final secKey = generateSecWebSocketKey();
    final request = buildWebSocketUpgradeRequest(
      host: peerOnion,
      path: '/ws',
      secWebSocketKey: secKey,
    );

    socksSocket.add(utf8.encode(request));
    await socksSocket.flush();

    final headerBytes = await readUntilHeaderEnd(
      socksSocket,
      timeout: timeout,
    );
    final headers = utf8.decode(headerBytes);
    if (!isWebSocketUpgradeResponse(headers, secWebSocketKey: secKey)) {
      throw HttpException(
        'WebSocket upgrade failed: ${headers.split('\r\n').first}',
      );
    }

    return WebSocket.fromUpgradedSocket(
      socksSocket,
      serverSide: false,
    );
  } catch (e) {
      if (socksSocket != null) {
        try {
          socksSocket.destroy();
        } catch (_) {}
      }
    rethrow;
  }
}
