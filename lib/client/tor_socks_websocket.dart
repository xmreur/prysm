import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
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

/// Returns true when [headers] contain a 101 Switching Protocols response.
bool isWebSocketUpgradeResponse(String headers) {
  final firstLine = headers.split('\r\n').first.trim();
  return firstLine.contains('101');
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
    if (!isWebSocketUpgradeResponse(headers)) {
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
