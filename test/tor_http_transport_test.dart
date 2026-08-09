import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/client/TorHttpClient.dart';
import 'package:prysm/transport/tor_http_transport.dart';
import 'package:prysm/util/tor_delivery.dart';
import 'package:prysm/util/tor_lifecycle_state.dart';
import 'package:prysm/util/tor_runtime_gate.dart';
import 'package:prysm/util/tor_service.dart';

void main() {
  setUp(() {
    TorRuntimeGate.resetForTest();
    TorDelivery.resetForTest();
  });

  tearDown(() {
    TorRuntimeGate.resetForTest(lifecycle: TorLifecycleState.stopped);
    TorDelivery.resetForTest();
  });

  group('TorHttpTransport', () {
    test('allows concurrent operations for the same peer', () async {
      final transport = TorHttpTransport.createForTest(
        TorManager(torPath: '/bin/false', dataDir: '/tmp/http-transport-test', controlPassword: 'test-password'),
      );
      final log = <String>[];

      Future<void> op(String name) {
        return transport.runForPeer('peer1.onion', () async {
          log.add('$name-start');
          await Future<void>.delayed(const Duration(milliseconds: 20));
          log.add('$name-end');
        });
      }

      await Future.wait([op('a'), op('b')]);
      expect(log.where((e) => e.endsWith('-start')).length, 2);
      expect(log.where((e) => e.endsWith('-end')).length, 2);
      transport.dispose();
    });

    test('allows another peer while first peer operation is in flight', () async {
      final transport = TorHttpTransport.createForTest(
        TorManager(torPath: '/bin/false', dataDir: '/tmp/http-transport-test-2', controlPassword: 'test-password'),
      );
      final peerAStarted = Completer<void>();
      final peerBStarted = Completer<void>();

      final peerAFuture = transport.runForPeer('peer-a.onion', () async {
        peerAStarted.complete();
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });

      await peerAStarted.future;
      final peerBFuture = transport.runForPeer('peer-b.onion', () async {
        peerBStarted.complete();
      });

      await peerBStarted.future.timeout(const Duration(milliseconds: 30));
      await Future.wait([peerAFuture, peerBFuture]);
      transport.dispose();
    });

    test('postJson throws on a 4xx status instead of reporting success',
        () async {
      final transport = TorHttpTransport.createForTest(
        TorManager(torPath: '/bin/false', dataDir: '/tmp/http-transport-4xx', controlPassword: 'test-password'),
      );
      addTearDown(transport.dispose);
      TorHttpTransport.clientFactory = () => _FakeTorHttpClient(
        _FakeHttpClientResponse(400, '{"error":"Message modify target not found"}'),
      );

      try {
        await expectLater(
          transport.postJson(
            peerOnion: 'peer.onion',
            path: 'message',
            payload: const {'a': 1},
          ),
          throwsA(isA<StateError>()),
        );
      } finally {
        TorHttpTransport.clientFactory = null;
      }
    });

    test('postJson throws on a 5xx status instead of reporting success',
        () async {
      final transport = TorHttpTransport.createForTest(
        TorManager(torPath: '/bin/false', dataDir: '/tmp/http-transport-5xx', controlPassword: 'test-password'),
      );
      addTearDown(transport.dispose);
      TorHttpTransport.clientFactory = () => _FakeTorHttpClient(
        _FakeHttpClientResponse(500, '{"error":"Processing failed"}'),
      );

      try {
        await expectLater(
          transport.postJson(
            peerOnion: 'peer.onion',
            path: 'message',
            payload: const {'a': 1},
          ),
          throwsA(isA<StateError>()),
        );
      } finally {
        TorHttpTransport.clientFactory = null;
      }
    });

    test('postJson returns normally on a 2xx status', () async {
      final transport = TorHttpTransport.createForTest(
        TorManager(torPath: '/bin/false', dataDir: '/tmp/http-transport-2xx', controlPassword: 'test-password'),
      );
      addTearDown(transport.dispose);
      TorHttpTransport.clientFactory = () => _FakeTorHttpClient(
        _FakeHttpClientResponse(200, '{"status":"received"}'),
      );

      try {
        await transport.postJson(
          peerOnion: 'peer.onion',
          path: 'message',
          payload: const {'a': 1},
        );
      } finally {
        TorHttpTransport.clientFactory = null;
      }
    });
  });
}

/// [TorHttpClient] whose [post] answers with a canned response, so
/// [TorHttpTransport.postJson]'s production status handling is exercised
/// without a live Tor circuit. The inherited [TorHttpClient.readUtf8Body] is
/// the production body reader.
class _FakeTorHttpClient extends TorHttpClient {
  _FakeTorHttpClient(this.response)
      : super(proxyHost: '127.0.0.1', proxyPort: 9050);

  final HttpClientResponse response;

  @override
  Future<HttpClientResponse> post(
    Uri uri,
    Map<String, String> headers,
    String body,
  ) async =>
      response;
}

/// Minimal [HttpClientResponse]: only [statusCode] and the byte stream
/// consumed by [TorHttpClient.readUtf8Body] are implemented; every other
/// member falls through to [Object.noSuchMethod].
class _FakeHttpClientResponse implements HttpClientResponse {
  _FakeHttpClientResponse(this.statusCode, this.body);

  @override
  final int statusCode;

  final String body;

  @override
  Stream<S> transform<S>(StreamTransformer<List<int>, S> transformer) =>
      Stream<List<int>>.value(utf8.encode(body)).transform(transformer);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
