import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/client/tor_socks_websocket.dart';
import 'package:prysm/database/messages.dart';
import 'package:prysm/services/ws_connection_manager.dart';
import 'package:prysm/transport/ws_peer_link.dart';
import 'package:prysm/util/tor_lifecycle_state.dart';
import 'package:prysm/util/tor_runtime_gate.dart';
import 'package:prysm/util/tor_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<Database> _openMessagesDb() async {
  final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
  await db.execute('DROP TABLE IF EXISTS messages');
  await db.execute('''
    CREATE TABLE messages(
      id TEXT PRIMARY KEY,
      senderId TEXT NOT NULL,
      receiverId TEXT NOT NULL,
      message TEXT,
      type TEXT,
      fileName TEXT,
      fileSize INTEGER,
      timestamp INTEGER NOT NULL,
      status TEXT DEFAULT 'sent',
      replyTo TEXT,
      readAt INTEGER,
      viewOnce INTEGER DEFAULT 0,
      viewed INTEGER DEFAULT 0,
      groupId TEXT,
      deletedAt INTEGER,
      editedAt INTEGER
    )
  ''');
  return db;
}

/// Polls [predicate] until it returns true or [timeout] elapses.
Future<void> _waitFor(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition not met within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}

/// A [TorManager] whose local onion is already provisioned (hostname file) and
/// whose SOCKS port points at a local fake server, so the production dial path
/// runs without a Tor daemon.
TorManager _torManagerWithOnion({
  required String dataDir,
  required int socksPort,
}) {
  Directory('$dataDir/hidden_service').createSync(recursive: true);
  File('$dataDir/hidden_service/hostname').writeAsStringSync('me.onion');
  return TorManager(
    torPath: '/bin/false',
    dataDir: dataDir,
    controlPassword: 'test-password',
    socksPort: socksPort,
  );
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() {
    TorRuntimeGate.resetForTest();
  });

  tearDown(() {
    TorRuntimeGate.resetForTest(lifecycle: TorLifecycleState.stopped);
  });

  test('interactive connect budget is 25 seconds', () {
    expect(
      WsConnectionManager.interactiveConnectBudget,
      const Duration(seconds: 25),
    );
  });

  test('ensureConnected rejects when Tor is stopped', () async {
    TorRuntimeGate.resetForTest(lifecycle: TorLifecycleState.stopped);
    TorRuntimeGate.isTorStopped = () => true;
    final manager = WsConnectionManager(
      TorManager(torPath: '/bin/false', dataDir: '/tmp/ws-manager-test-2', controlPassword: 'test-password'),
    );

    await expectLater(
      manager.ensureConnected('peer.onion'),
      throwsA(isA<StateError>()),
    );

    manager.dispose();
  });

  test('registerLinkForTest marks peer connected', () {
    final manager = WsConnectionManager(
      TorManager(torPath: '/bin/false', dataDir: '/tmp/ws-manager-inbound', controlPassword: 'test-password'),
    );

    final link = _FakeWsPeerLink('peer.onion');
    manager.registerLinkForTest('peer.onion', link);
    expect(manager.isConnected('peer.onion'), isTrue);

    manager.dispose();
  });

  test('prepareForTorReconnect clears links', () {
    final manager = WsConnectionManager(
      TorManager(torPath: '/bin/false', dataDir: '/tmp/ws-manager-reconnect', controlPassword: 'test-password'),
    );

    manager.registerLinkForTest('peer.onion', _FakeWsPeerLink('peer.onion'));
    expect(manager.isConnected('peer.onion'), isTrue);

    manager.prepareForTorReconnect();
    expect(manager.isConnected('peer.onion'), isFalse);

    manager.dispose();
  });

  test('request calls are serialized per peer', () async {
    final manager = WsConnectionManager(
      TorManager(torPath: '/bin/false', dataDir: '/tmp/ws-manager-queue', controlPassword: 'test-password'),
    );
    final link = _RecordingWsPeerLink('peer.onion');
    manager.registerLinkForTest('peer.onion', link);

    final first = manager.request('peer.onion', 'first');
    final second = manager.request('peer.onion', 'second');
    await Future.wait([first, second]);

    expect(link.ops, ['first', 'second']);
    manager.dispose();
  });

  test('interactive connect fails fast while peer is in backoff', () async {
    final manager = WsConnectionManager(
      TorManager(torPath: '/bin/false', dataDir: '/tmp/ws-manager-backoff', controlPassword: 'test-password'),
    );
    manager.recordConnectFailureForTest(
      'peer.onion',
      Exception('SocksClientConnectionCommandFailedException: hostUnreachable'),
    );
    // A single failure puts the peer in backoff (fast-fail applies) but is not
    // enough to count it as genuinely unreachable for wake-hint suppression.
    expect(manager.retryDelayForTest('peer.onion'), isNotNull);
    expect(manager.isPeerUnreachable('peer.onion'), isFalse);

    await expectLater(
      manager.ensureConnected(
        'peer.onion',
        connectBudget: WsConnectionManager.interactiveConnectBudget,
      ),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('backoff'),
        ),
      ),
    );

    manager.dispose();
  });

  test('quarantine caps retry frequency after repeated hostUnreachable failures',
      () async {
    final manager = WsConnectionManager(
      TorManager(torPath: '/bin/false', dataDir: '/tmp/ws-manager-quarantine', controlPassword: 'test-password'),
    );
    for (var i = 0; i < WsConnectionManager.hostUnreachableQuarantineThreshold;
        i++) {
      manager.recordConnectFailureForTest(
        'peer.onion',
        Exception('SocksClientConnectionCommandFailedException: hostUnreachable'),
      );
    }

    // Quarantine pushes the next retry well past the 2-minute backoff cap.
    final delay = manager.retryDelayForTest('peer.onion');
    expect(delay, isNotNull);
    expect(delay!, greaterThan(const Duration(minutes: 2)));

    // An explicit user action clears the quarantine immediately.
    manager.pinPeer('peer.onion');
    expect(manager.retryDelayForTest('peer.onion'), isNull);
    expect(manager.isPeerUnreachable('peer.onion'), isFalse);

    manager.dispose();
  });

  test('a non-peer-reachability failure breaks the quarantine streak', () async {
    final manager = WsConnectionManager(
      TorManager(torPath: '/bin/false', dataDir: '/tmp/ws-manager-quarantine-mixed', controlPassword: 'test-password'),
    );
    final hostUnreachable =
        Exception('SocksClientConnectionCommandFailedException: hostUnreachable');
    for (var i = 0;
        i < WsConnectionManager.hostUnreachableQuarantineThreshold - 1;
        i++) {
      manager.recordConnectFailureForTest('peer.onion', hostUnreachable);
    }
    // A local state error (no local onion) is not the peer's fault: unlike a
    // retryable dial failure (which includes timeouts), it breaks the streak.
    manager.recordConnectFailureForTest(
      'peer.onion',
      StateError('Local onion address not available'),
    );

    final delay = manager.retryDelayForTest('peer.onion');
    expect(delay, isNotNull);
    expect(delay!, lessThanOrEqualTo(const Duration(minutes: 2)));

    manager.dispose();
  });

  test('registering an inbound link clears throttling state', () async {
    final manager = WsConnectionManager(
      TorManager(torPath: '/bin/false', dataDir: '/tmp/ws-manager-quarantine-inbound', controlPassword: 'test-password'),
    );
    for (var i = 0; i < WsConnectionManager.hostUnreachableQuarantineThreshold;
        i++) {
      manager.recordConnectFailureForTest(
        'peer.onion',
        Exception('SocksClientConnectionCommandFailedException: hostUnreachable'),
      );
    }
    expect(manager.isPeerUnreachable('peer.onion'), isTrue);

    manager.registerLinkForTest('peer.onion', _FakeWsPeerLink('peer.onion'));

    expect(manager.isPeerUnreachable('peer.onion'), isFalse);
    expect(manager.retryDelayForTest('peer.onion'), isNull);

    manager.dispose();
  });

  test(
    'quarantine engages on the production path after repeated real dial failures',
    () async {
      final socks = _FakeSocksServer(mode: _FakeSocksMode.close);
      await socks.start();
      addTearDown(socks.close);
      final db = await _openMessagesDb();
      MessagesDb.setDatabaseForTest(db);
      addTearDown(() async {
        await db.close();
        MessagesDb.setDatabaseForTest(null);
      });
      await db.insert('messages', {
        'id': 'm1',
        'senderId': 'peer.onion',
        'receiverId': 'me.onion',
        'message': 'hello',
        'type': 'text',
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'status': 'received',
      });

      final manager = WsConnectionManager(
        _torManagerWithOnion(
          dataDir: Directory.systemTemp.createTempSync('ws-manager-q').path,
          socksPort: socks.port,
        ),
      );
      addTearDown(manager.dispose);

      // The real heartbeat loop dials the peer and records the failure each
      // cycle. Drive it through the production start()/stop() entry points
      // (stop() only clears the retry window; the failure counters and the
      // unreachable streak survive it).
      manager.start();
      await _waitFor(() => manager.retryDelayForTest('peer.onion') != null);
      for (var i = 1;
          i < WsConnectionManager.hostUnreachableQuarantineThreshold;
          i++) {
        manager.stop();
        manager.start();
        await _waitFor(() => manager.retryDelayForTest('peer.onion') != null);
      }

      // The dials fail with a socket-level error (connection reset), not a
      // `hostUnreachable` SOCKS reply — the shape the device log shows for
      // dead peers. Ten of those on the production path must still engage the
      // quarantine: the retry window jumps from the 2-minute cap to 10 minutes.
      final delay = manager.retryDelayForTest('peer.onion');
      expect(delay, isNotNull);
      expect(delay!, greaterThan(const Duration(minutes: 2)));

      // An explicit user action clears the quarantine immediately.
      manager.pinPeer('peer.onion');
      expect(manager.retryDelayForTest('peer.onion'), isNull);
      expect(manager.isPeerUnreachable('peer.onion'), isFalse);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'quarantine is authoritative: survives stop()/start(), gates wake hints '
    'through the final minute, and clears on a successful connect',
    () async {
      var now = DateTime.now();
      final socks = _FakeSocksServer(mode: _FakeSocksMode.close);
      await socks.start();
      addTearDown(socks.close);
      final db = await _openMessagesDb();
      MessagesDb.setDatabaseForTest(db);
      addTearDown(() async {
        await db.close();
        MessagesDb.setDatabaseForTest(null);
      });
      await db.insert('messages', {
        'id': 'm1',
        'senderId': 'peer.onion',
        'receiverId': 'me.onion',
        'message': 'hello',
        'type': 'text',
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'status': 'received',
      });

      final manager = WsConnectionManager(
        _torManagerWithOnion(
          dataDir: Directory.systemTemp.createTempSync('ws-manager-q-auth').path,
          socksPort: socks.port,
        ),
        now: () => now,
      );
      addTearDown(manager.dispose);

      // Drive 10 real dial failures through the production heartbeat path.
      manager.start();
      await _waitFor(() => manager.retryDelayForTest('peer.onion') != null);
      for (var i = 1;
          i < WsConnectionManager.hostUnreachableQuarantineThreshold;
          i++) {
        manager.stop();
        manager.start();
        await _waitFor(() => manager.retryDelayForTest('peer.onion') != null);
      }
      expect(manager.isPeerUnreachable('peer.onion'), isTrue);

      // (b) The quarantine gates wake hints for its whole window: with only
      // 30s left, the retry bookkeeping is below the 60s hint-suppression
      // threshold, but the peer must still count as unreachable —
      // WakeHintService filters hints on exactly this predicate.
      now = now.add(
        WsConnectionManager.hostUnreachableQuarantine -
            const Duration(seconds: 30),
      );
      expect(manager.isPeerUnreachable('peer.onion'), isTrue);

      // (a) stop() clears the retry bookkeeping but must not lift the gate:
      // the quarantined peer stays in backoff and hint-suppressed.
      manager.stop();
      expect(manager.retryDelayForTest('peer.onion'), isNull);
      expect(manager.isPeerUnreachable('peer.onion'), isTrue);
      await expectLater(
        manager.ensureConnected(
          'peer.onion',
          connectBudget: WsConnectionManager.interactiveConnectBudget,
        ),
        throwsA(isA<PeerInBackoffError>()),
      );
      // The restarted heartbeat loop must skip the quarantined peer entirely.
      manager.start();
      final dialsBefore = socks.dialCount;
      await Future<void>.delayed(const Duration(seconds: 4));
      expect(socks.dialCount, dialsBefore);
      manager.stop();

      // (c) Once the window elapses and the peer proves reachable again, the
      // successful connect clears the quarantine alongside the backoff.
      now = now.add(const Duration(seconds: 31));
      await socks.setMode(_FakeSocksMode.success);
      manager.start();
      await _waitFor(() => manager.isConnected('peer.onion'));
      expect(manager.isPeerUnreachable('peer.onion'), isFalse);
      expect(manager.retryDelayForTest('peer.onion'), isNull);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test('a fast-fail while the peer is in backoff does not extend the window',
      () async {
    final socks = _FakeSocksServer(mode: _FakeSocksMode.hostUnreachable);
    await socks.start();
    addTearDown(socks.close);
    final db = await _openMessagesDb();
    MessagesDb.setDatabaseForTest(db);
    addTearDown(() async {
      await db.close();
      MessagesDb.setDatabaseForTest(null);
    });
    await db.insert('messages', {
      'id': 'm1',
      'senderId': 'peer.onion',
      'receiverId': 'me.onion',
      'message': 'hello',
      'type': 'text',
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'status': 'received',
    });

    final manager = WsConnectionManager(
      _torManagerWithOnion(
        dataDir: Directory.systemTemp.createTempSync('ws-manager-fastfail').path,
        socksPort: socks.port,
      ),
    );
    addTearDown(manager.dispose);
    manager.start();
    await _waitFor(() => manager.retryDelayForTest('peer.onion') != null);

    // User-initiated connect against the throttled peer still fails fast...
    await expectLater(
      manager.ensureConnected(
        'peer.onion',
        connectBudget: WsConnectionManager.interactiveConnectBudget,
      ),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('backoff'),
        ),
      ),
    );

    // ...and must not have been recorded as a fresh failure: the window stays
    // the original 1s backoff instead of re-arming to 2s.
    final delay = manager.retryDelayForTest('peer.onion');
    expect(delay, isNotNull);
    expect(delay!, lessThan(const Duration(seconds: 2)));
  });

  test('a peer is re-dialled after its backoff elapses and recovers', () async {
    final socks = _FakeSocksServer(mode: _FakeSocksMode.hostUnreachable);
    await socks.start();
    addTearDown(socks.close);
    final db = await _openMessagesDb();
    MessagesDb.setDatabaseForTest(db);
    addTearDown(() async {
      await db.close();
      MessagesDb.setDatabaseForTest(null);
    });
    await db.insert('messages', {
      'id': 'm1',
      'senderId': 'peer.onion',
      'receiverId': 'me.onion',
      'message': 'hello',
      'type': 'text',
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'status': 'received',
    });

    final manager = WsConnectionManager(
      _torManagerWithOnion(
        dataDir: Directory.systemTemp.createTempSync('ws-manager-recover').path,
        socksPort: socks.port,
      ),
    );
    addTearDown(manager.dispose);
    manager.start();
    await _waitFor(() => manager.retryDelayForTest('peer.onion') != null);
    expect(socks.dialCount, greaterThanOrEqualTo(1));

    // Let the short backoff elapse, then make the peer reachable: the next
    // dial must actually happen (not be swallowed by a self-perpetuating
    // window) and must recover the peer.
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    await socks.setMode(_FakeSocksMode.success);
    manager.warmPeer('peer.onion');
    await _waitFor(() => manager.isConnected('peer.onion'));

    expect(socks.dialCount, greaterThan(1));
    expect(manager.isConnected('peer.onion'), isTrue);
    expect(manager.isPeerUnreachable('peer.onion'), isFalse);
    expect(manager.retryDelayForTest('peer.onion'), isNull);
  });
}

class _RecordingWsPeerLink implements WsPeerLink {
  _RecordingWsPeerLink(this.peerOnion);

  @override
  final String peerOnion;

  final List<String> ops = [];

  @override
  bool isConnected = true;

  @override
  Stream<Map<String, dynamic>> get onPushFrames =>
      const Stream<Map<String, dynamic>>.empty();

  @override
  Stream<List<int>> get onBinaryFrames => const Stream<List<int>>.empty();

  @override
  Future<void> close() async {
    isConnected = false;
  }

  @override
  Future<Map<String, dynamic>> request(
    String op, {
    Map<String, dynamic>? payload,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    ops.add(op);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    return <String, dynamic>{};
  }

  @override
  Future<void> send(String op, {Map<String, dynamic>? payload}) async {}

  @override
  Future<void> sendBytes(List<int> bytes) async {}

  @override
  Future<void> sendPing() async {}
}

class _FakeWsPeerLink implements WsPeerLink {
  _FakeWsPeerLink(this.peerOnion);

  @override
  final String peerOnion;

  @override
  bool isConnected = true;

  @override
  Stream<Map<String, dynamic>> get onPushFrames =>
      const Stream<Map<String, dynamic>>.empty();

  @override
  Stream<List<int>> get onBinaryFrames => const Stream<List<int>>.empty();

  @override
  Future<void> close() async {
    isConnected = false;
  }

  @override
  Future<Map<String, dynamic>> request(
    String op, {
    Map<String, dynamic>? payload,
    Duration timeout = const Duration(seconds: 30),
  }) async =>
      <String, dynamic>{};

  @override
  Future<void> send(String op, {Map<String, dynamic>? payload}) async {}

  @override
  Future<void> sendBytes(List<int> bytes) async {}

  @override
  Future<void> sendPing() async {}
}

/// Failure/success mode for [_FakeSocksServer].
enum _FakeSocksMode {
  /// Accept then immediately destroy: the dial fails with a socket-level
  /// error (connection reset), the dominant dead-peer shape in the device log.
  close,

  /// Answer the SOCKS CONNECT with 0x04 (host unreachable).
  hostUnreachable,

  /// Complete the SOCKS + WebSocket handshake so the dial succeeds.
  success,
}

/// Minimal local SOCKS5/WebSocket server that lets the production dial path
/// ([TorWebSocketClient.connect]) fail or succeed deterministically without a
/// Tor daemon. Mirrors the real wire protocol the client speaks.
class _FakeSocksServer {
  _FakeSocksServer({this.mode = _FakeSocksMode.hostUnreachable});

  _FakeSocksMode mode;
  ServerSocket? _server;
  int dialCount = 0;

  int get port => _server!.port;

  Future<void> start() async {
    _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen(_handleClient);
  }

  Future<void> setMode(_FakeSocksMode next) async {
    mode = next;
  }

  Future<void> close() async {
    await _server?.close();
    _server = null;
  }

  Future<void> _handleClient(Socket client) async {
    dialCount++;
    final currentMode = mode;
    if (currentMode == _FakeSocksMode.close) {
      client.destroy();
      return;
    }
    try {
      final reader = _SocksReader(client);
      // SOCKS5 greeting: version, nmethods, methods.
      final greeting = await reader.readN(3);
      if (greeting[0] != 5) {
        client.destroy();
        return;
      }
      client.add([5, 0]); // no authentication
      await client.flush();
      // SOCKS5 CONNECT request: version, cmd, rsv, atyp, address, port.
      final header = await reader.readN(4);
      final atyp = header[3];
      final addrLen = switch (atyp) {
        1 => 4,
        3 => (await reader.readN(1))[0],
        4 => 16,
        _ => -1,
      };
      if (addrLen < 0) {
        client.destroy();
        return;
      }
      await reader.readN(addrLen + 2);

      if (currentMode == _FakeSocksMode.hostUnreachable) {
        // 0x04 = host unreachable: the exact reply a dead peer yields.
        client.add([5, 4, 0, 1, 0, 0, 0, 0, 0, 0]);
        await client.flush();
        client.destroy();
        return;
      }

      // success: accept the connection and complete the WebSocket upgrade.
      client.add([5, 0, 0, 1, 0, 0, 0, 0, 0, 0]);
      await client.flush();
      final upgrade = utf8.decode(await reader.readUntil([13, 10, 13, 10]));
      final key = RegExp(r'Sec-WebSocket-Key:\s*(\S+)', caseSensitive: false)
          .firstMatch(upgrade)
          ?.group(1);
      if (key == null) {
        client.destroy();
        return;
      }
      client.add(utf8.encode(
        'HTTP/1.1 101 Switching Protocols\r\n'
        'Upgrade: websocket\r\n'
        'Connection: Upgrade\r\n'
        'Sec-WebSocket-Accept: ${computeWebSocketAccept(key)}\r\n\r\n',
      ));
      await client.flush();
      // Server-side hello completes the client's handshake.
      final hello = utf8.encode('{"v":1,"op":"hello","payload":{"supports":[]}}');
      client.add([0x81, hello.length, ...hello]);
      await client.flush();
      // Keep the socket open: the client owns it from here.
    } catch (_) {
      client.destroy();
    }
  }
}

/// Incremental reader over a socket's byte stream.
class _SocksReader {
  _SocksReader(Socket socket) {
    socket.listen(
      (chunk) {
        _buffer.addAll(chunk);
        _wakeUp();
      },
      onDone: () {
        _closed = true;
        _wakeUp();
      },
      onError: (_) {
        _closed = true;
        _wakeUp();
      },
    );
  }

  final List<int> _buffer = [];
  final List<Completer<void>> _wake = [];
  bool _closed = false;

  void _wakeUp() {
    for (final c in _wake) {
      if (!c.isCompleted) c.complete();
    }
    _wake.clear();
  }

  Future<void> _changed() async {
    if (_buffer.isNotEmpty || _closed) return;
    final c = Completer<void>();
    _wake.add(c);
    await c.future.timeout(const Duration(seconds: 10));
  }

  Future<List<int>> readN(int n) async {
    while (_buffer.length < n) {
      if (_closed) throw StateError('socket closed before $n bytes');
      await _changed();
    }
    final out = _buffer.sublist(0, n);
    _buffer.removeRange(0, n);
    return out;
  }

  Future<List<int>> readUntil(List<int> terminator) async {
    while (true) {
      for (var i = 0; i + terminator.length <= _buffer.length; i++) {
        var match = true;
        for (var j = 0; j < terminator.length; j++) {
          if (_buffer[i + j] != terminator[j]) {
            match = false;
            break;
          }
        }
        if (match) {
          final out = _buffer.sublist(0, i + terminator.length);
          _buffer.removeRange(0, i + terminator.length);
          return out;
        }
      }
      if (_closed) throw StateError('socket closed before terminator');
      await _changed();
    }
  }
}
