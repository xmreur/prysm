import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/client/tor_socks_websocket.dart';

void main() {
  test('buildWebSocketUpgradeRequest includes required headers', () {
    const key = 'dGhlIHNhbXBsZSBub25jZQ==';
    final request = buildWebSocketUpgradeRequest(
      host: 'peer.onion',
      path: '/ws',
      secWebSocketKey: key,
    );

    expect(request, contains('GET /ws HTTP/1.1'));
    expect(request, contains('Host: peer.onion'));
    expect(request, contains('Upgrade: websocket'));
    expect(request, contains('Connection: Upgrade'));
    expect(request, contains('Sec-WebSocket-Key: $key'));
    expect(request, contains('Sec-WebSocket-Version: 13'));
    expect(request, endsWith('\r\n\r\n'));
  });

  test('isWebSocketUpgradeResponse accepts 101 responses', () {
    expect(
      isWebSocketUpgradeResponse(
        'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n\r\n',
      ),
      isTrue,
    );
    expect(
      isWebSocketUpgradeResponse('HTTP/1.1 404 Not Found\r\n\r\n'),
      isFalse,
    );
  });

  test('generateSecWebSocketKey returns base64 payload', () {
    final key = generateSecWebSocketKey();
    expect(key.length, greaterThan(10));
    expect(RegExp(r'^[A-Za-z0-9+/=]+$').hasMatch(key), isTrue);
  });

  test('readUntilHeaderEnd stops at header terminator', () async {
    final stream = Stream<List<int>>.fromIterable([
      utf8.encode('HTTP/1.1 101 Switching Protocols\r\n'),
      utf8.encode('Upgrade: websocket\r\n\r\nEXTRA'),
    ]);

    final bytes = await readUntilHeaderEnd(stream);
    expect(utf8.decode(bytes), contains('101 Switching Protocols'));
  });
}
