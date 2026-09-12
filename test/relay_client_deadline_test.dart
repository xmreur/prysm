/// `RelayClient` against a loopback SOCKS5 proxy that also plays the origin:
/// the real handshake, the real HTTP client, no Tor. The defects covered here
/// are both about what the client does when a relay misbehaves.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/transport/relay_client.dart';
import 'package:prysm/util/tor_delivery.dart';
import 'package:prysm_relay_protocol/prysm_relay_protocol.dart';

const _relayOnion =
    'k5cjn3lna3yaxx2hbgnofqln45dbythuj5d4ekzkf42jy3e6mkgst2yd.onion';

/// Speaks just enough SOCKS5 to be accepted by `TorHttpClient`, then answers
/// HTTP itself. [stallBody] sends the headers and one byte of a 64-byte body
/// and never sends the rest: the shape of a relay that accepts a request and
/// then goes quiet.
class _FakeRelay {
  _FakeRelay(this._server);

  final ServerSocket _server;
  final List<String> requests = [];

  int get port => _server.port;

  static Future<_FakeRelay> start({required bool stallBody}) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final relay = _FakeRelay(server);
    server.listen((socket) {
      final buffer = <int>[];
      var stage = 0;
      socket.listen((data) {
        buffer.addAll(data);
        if (stage == 0) {
          if (buffer.length < 2) return;
          final methods = buffer[1];
          if (buffer.length < 2 + methods) return;
          buffer.removeRange(0, 2 + methods);
          socket.add([5, 0]);
          stage = 1;
        }
        if (stage == 1) {
          if (buffer.length < 5) return;
          final atyp = buffer[3];
          final need = switch (atyp) {
            1 => 4 + 4 + 2,
            3 => 4 + 1 + buffer[4] + 2,
            _ => 4 + 16 + 2,
          };
          if (buffer.length < need) return;
          buffer.removeRange(0, need);
          socket.add([5, 0, 0, 1, 0, 0, 0, 0, 0, 0]);
          stage = 2;
        }
        if (stage == 2) {
          final text = utf8.decode(buffer, allowMalformed: true);
          final headerEnd = text.indexOf('\r\n\r\n');
          if (headerEnd < 0) return;
          relay.requests.add(text.substring(0, headerEnd));
          buffer.clear();
          if (stallBody) {
            socket.add(
              utf8.encode(
                'HTTP/1.1 200 OK\r\n'
                'Content-Type: application/json\r\n'
                'Content-Length: 64\r\n\r\n{',
              ),
            );
          } else {
            const body = '{"status":"ok"}';
            socket.add(
              utf8.encode(
                'HTTP/1.1 200 OK\r\n'
                'Content-Type: application/json\r\n'
                'Content-Length: ${body.length}\r\n\r\n$body',
              ),
            );
          }
        }
      }, onError: (_) {}, cancelOnError: true);
    });
    return relay;
  }

  Future<void> close() => _server.close();
}

void main() {
  setUp(TorDelivery.resetForTest);

  test('a relay that stalls mid-body hits the timeout instead of hanging',
      () async {
    final relay = await _FakeRelay.start(stallBody: true);
    addTearDown(relay.close);
    final client = RelayClient(relayOnion: _relayOnion, socksPort: relay.port);

    await expectLater(
      client.deposit(
        deposit: 'a' * 64,
        payload: const {'scheme': 'relay-sealed-1'},
        timeout: const Duration(milliseconds: 400),
      ),
      throwsA(isA<TimeoutException>()),
    );
    expect(relay.requests, hasLength(1));
  });

  test('a full answer still decodes through the same path', () async {
    final relay = await _FakeRelay.start(stallBody: false);
    addTearDown(relay.close);
    final client = RelayClient(relayOnion: _relayOnion, socksPort: relay.port);

    final json = await client.authed(
      RelayProtocol.pathAck,
      const {'protocol': RelayProtocol.id},
      auth: RelayAuth(
        relayFingerprint: 'a' * 64,
        ownerFingerprint: 'b' * 64,
        signKeyPair: await Ed25519().newKeyPair(),
      ),
      timeout: const Duration(seconds: 5),
    );

    expect(json['status'], 'ok');
    expect(relay.requests.single, contains('POST ${RelayProtocol.pathAck}'));
  });
}
