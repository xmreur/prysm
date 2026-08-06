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

  test('isWebSocketUpgradeResponse validates Sec-WebSocket-Accept', () {
    // RFC 6455 §1.3 worked example: key `dGhlIHNhbXBsZSBub25jZQ==` must be
    // answered with `s3pPLMBiTxaQ9kYGzzhZRbK+xOo=`.
    const key = 'dGhlIHNhbXBsZSBub25jZQ==';
    const expectedAccept = 's3pPLMBiTxaQ9kYGzzhZRbK+xOo=';

    // Correct accept derived from the key sent in the request: accepted.
    expect(
      isWebSocketUpgradeResponse(
        'HTTP/1.1 101 Switching Protocols\r\n'
        'Upgrade: websocket\r\n'
        'Sec-WebSocket-Accept: $expectedAccept\r\n\r\n',
        secWebSocketKey: key,
      ),
      isTrue,
    );

    // 101 with a wrong accept: refused.
    expect(
      isWebSocketUpgradeResponse(
        'HTTP/1.1 101 Switching Protocols\r\n'
        'Upgrade: websocket\r\n'
        'Sec-WebSocket-Accept: AAA=\r\n\r\n',
        secWebSocketKey: key,
      ),
      isFalse,
    );

    // 101 without the accept header: refused.
    expect(
      isWebSocketUpgradeResponse(
        'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n\r\n',
        secWebSocketKey: key,
      ),
      isFalse,
    );

    // Non-101: refused.
    expect(
      isWebSocketUpgradeResponse(
        'HTTP/1.1 404 Not Found\r\n\r\n',
        secWebSocketKey: key,
      ),
      isFalse,
    );
  });

  test('isWebSocketUpgradeResponse requires 101 as the status-code token', () {
    // RFC 6455 §1.3 worked example: key `dGhlIHNhbXBsZSBub25jZQ==` must be
    // answered with `s3pPLMBiTxaQ9kYGzzhZRbK+xOo=`.
    const key = 'dGhlIHNhbXBsZSBub25jZQ==';
    const expectedAccept = 's3pPLMBiTxaQ9kYGzzhZRbK+xOo=';

    // A bare substring check would accept `101` inside the status code
    // (`1010`) or the reason phrase (`400 Error 101`); only the status-code
    // token itself counts.
    expect(
      isWebSocketUpgradeResponse(
        'HTTP/1.1 1010 Switching Protocols\r\n'
        'Sec-WebSocket-Accept: $expectedAccept\r\n\r\n',
        secWebSocketKey: key,
      ),
      isFalse,
    );
    expect(
      isWebSocketUpgradeResponse(
        'HTTP/1.1 400 Error 101\r\n'
        'Sec-WebSocket-Accept: $expectedAccept\r\n\r\n',
        secWebSocketKey: key,
      ),
      isFalse,
    );

    // Well-formed 101 with the correct accept: accepted.
    expect(
      isWebSocketUpgradeResponse(
        'HTTP/1.1 101 Switching Protocols\r\n'
        'Sec-WebSocket-Accept: $expectedAccept\r\n\r\n',
        secWebSocketKey: key,
      ),
      isTrue,
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
