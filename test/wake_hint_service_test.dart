import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/database/messages.dart';
import 'package:prysm/services/settings_service.dart';
import 'package:prysm/services/wake_hint_service.dart';
import 'package:prysm/services/ws_connection_manager.dart';
import 'package:prysm/transport/transport_provider.dart';
import 'package:prysm/util/battery_saver_policy.dart';
import 'package:prysm/util/tor_lifecycle_state.dart';
import 'package:prysm/util/tor_runtime_gate.dart';
import 'package:prysm/util/tor_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
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

void main() {
  group('WakeHintService.validateSyncHintPayload', () {
    test('accepts valid payload', () {
      expect(
        WakeHintService.validateSyncHintPayload(
          {
            'senderId': 'peer.onion',
            'timestamp': DateTime.now().millisecondsSinceEpoch,
            'sig': 'dGVzdA==',
          },
          'me.onion',
        ),
        isNull,
      );
    });

    test('rejects self wake', () {
      expect(
        WakeHintService.validateSyncHintPayload(
          {
            'senderId': 'me.onion',
            'timestamp': DateTime.now().millisecondsSinceEpoch,
            'sig': 'dGVzdA==',
          },
          'me.onion',
        ),
        isNotNull,
      );
    });

    test('rejects stale timestamp', () {
      final stale = DateTime.now()
          .subtract(const Duration(minutes: 10))
          .millisecondsSinceEpoch;
      expect(
        WakeHintService.validateSyncHintPayload(
          {'senderId': 'peer.onion', 'timestamp': stale, 'sig': 'dGVzdA=='},
          'me.onion',
        ),
        isNotNull,
      );
    });
  });

  group('WakeHintService.handleIncomingHint', () {
    setUp(() {
      WakeHintService.instance.resetForTest();
    });

    test('skips flush when no pending outbound for sender', () async {
      var flushCount = 0;
      WakeHintService.instance.configure(
        userId: 'me.onion',
        onFlushPeer: (_) async {
          flushCount++;
          return true;
        },
        hasOutboundPendingForSender: (_) async => false,
      );

      await WakeHintService.instance.handleIncomingHint('peer.onion');
      expect(flushCount, 0);
    });

    test('flushes when pending outbound exists for sender', () async {
      String? flushedPeer;
      WakeHintService.instance.configure(
        userId: 'me.onion',
        onFlushPeer: (peerId) async {
          flushedPeer = peerId;
          return true;
        },
        hasOutboundPendingForSender: (_) async => true,
      );

      await WakeHintService.instance.handleIncomingHint('peer.onion');
      expect(flushedPeer, 'peer.onion');
    });

    test('debounces repeated hints from same peer', () async {
      var flushCount = 0;
      WakeHintService.instance.configure(
        userId: 'me.onion',
        onFlushPeer: (_) async {
          flushCount++;
          return true;
        },
        hasOutboundPendingForSender: (_) async => true,
      );

      await WakeHintService.instance.handleIncomingHint('peer.onion');
      await WakeHintService.instance.handleIncomingHint('peer.onion');
      expect(flushCount, 1);
    });
  });

  group('WakeHintService.broadcastRecentPeerHints', () {
    late Database db;
    final sentHints = <Map<String, String>>[];

    setUpAll(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    });

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await SettingsService().init();

      WakeHintService.instance.resetForTest();
      sentHints.clear();

      db = await _openMessagesDb();
      MessagesDb.setDatabaseForTest(db);
      await db.insert('messages', {
        'id': 'm1',
        'senderId': 'peer.onion',
        'receiverId': 'me.onion',
        'message': 'hello',
        'type': 'text',
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'status': 'received',
      });

      TransportProvider.configure(
        TorManager(
          torPath: '/bin/false',
          dataDir: Directory.systemTemp.path,
          controlPassword: 'test-password',
        ),
      );

      WakeHintService.instance.configure(
        userId: 'me.onion',
        onFlushPeer: (_) async => true,
        postHint: ({required peerOnion, required senderId}) async {
          sentHints.add({'peerOnion': peerOnion, 'senderId': senderId});
        },
      );
    });

    tearDown(() async {
      WakeHintService.instance.resetForTest();
      await db.close();
      MessagesDb.setDatabaseForTest(null);
      TransportProvider.resetForTest();
    });

    test('does not send hints when showOnlineStatus is disabled', () async {
      await SettingsService().setShowOnlineStatus(false);

      await WakeHintService.instance.broadcastRecentPeerHints();

      expect(sentHints, isEmpty);
    });

    test('sends hints to recent peers when showOnlineStatus is enabled',
        () async {
      await SettingsService().setShowOnlineStatus(true);

      await WakeHintService.instance.broadcastRecentPeerHints();

      expect(sentHints, [
        {'peerOnion': 'peer.onion', 'senderId': 'me.onion'},
      ]);
    });

    test('skips peers with sustained connect failures', () async {
      await SettingsService().setShowOnlineStatus(true);

      // A single blip must NOT suppress hints; only the sustained dead-peer
      // regime (capped 120s backoff, i.e. ~7+ consecutive failures) does.
      for (var i = 0; i < 7; i++) {
        TransportProvider.instance.wsManager.recordConnectFailureForTest(
          'peer.onion',
          Exception(
            'SocksClientConnectionCommandFailedException: hostUnreachable',
          ),
        );
      }
      expect(
        TransportProvider.instance.wsManager.isPeerUnreachable('peer.onion'),
        isTrue,
      );

      await WakeHintService.instance.broadcastRecentPeerHints();

      expect(sentHints, isEmpty);
    });

    test('sends a wake hint after a single transient connect failure',
        () async {
      await SettingsService().setShowOnlineStatus(true);

      // Drive ONE real dial failure through the production path — the
      // maintenance heartbeat dial against a peer whose connection is reset —
      // then verify the hint still goes out: a single blip must not silence
      // the nudge that wakes a sleeping peer.
      final socks = _ClosingSocksServer();
      await socks.start();
      addTearDown(socks.close);
      final dataDir = Directory.systemTemp.createTempSync('ws-hint-onion');
      Directory('${dataDir.path}/hidden_service').createSync(recursive: true);
      File('${dataDir.path}/hidden_service/hostname')
          .writeAsStringSync('me.onion');
      final tor = TorManager(
        torPath: '/bin/false',
        dataDir: dataDir.path,
        controlPassword: 'test-password',
        socksPort: socks.port,
      );
      TorRuntimeGate.resetForTest();
      TransportProvider.resetForTest();
      TransportProvider.configure(tor);
      final wsManager = TransportProvider.instance.wsManager;
      wsManager.start();
      await _waitFor(() => wsManager.retryDelayForTest('peer.onion') != null);
      TorRuntimeGate.resetForTest(lifecycle: TorLifecycleState.stopped);

      // One failure recorded: the peer is in a 1s backoff, far below the
      // sustained-unreachable threshold.
      expect(wsManager.isPeerUnreachable('peer.onion'), isFalse);

      await WakeHintService.instance.broadcastRecentPeerHints();

      expect(sentHints, [
        {'peerOnion': 'peer.onion', 'senderId': 'me.onion'},
      ]);
    });

    test('incoming wake hint clears throttling state for that peer', () async {
      final wsManager = TransportProvider.instance.wsManager;
      for (var i = 0;
          i < WsConnectionManager.hostUnreachableQuarantineThreshold;
          i++) {
        wsManager.recordConnectFailureForTest(
          'peer.onion',
          Exception(
            'SocksClientConnectionCommandFailedException: hostUnreachable',
          ),
        );
      }
      expect(wsManager.isPeerUnreachable('peer.onion'), isTrue);

      // Re-configure with a pending-check seam so handleIncomingHint does not
      // touch the real pending_messages database.
      WakeHintService.instance.configure(
        userId: 'me.onion',
        onFlushPeer: (_) async => true,
        hasOutboundPendingForSender: (_) async => false,
      );

      await WakeHintService.instance.handleIncomingHint('peer.onion');

      expect(wsManager.isPeerUnreachable('peer.onion'), isFalse);
      expect(wsManager.retryDelayForTest('peer.onion'), isNull);
    });
  });

  test('wake hint policy constants are sensible', () {
    expect(BatterySaverPolicy.wakeHintMaxPeers, 20);
    expect(BatterySaverPolicy.wakeHintReceiveDebounce.inSeconds, 30);
    expect(BatterySaverPolicy.wakeHintSendCooldown.inMinutes, 5);
  });
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

/// Accepts and immediately destroys incoming TCP connections: the production
/// dial path fails with a socket-level error (connection reset), which the
/// connection manager records as a real dial failure — no SOCKS protocol
/// needed.
class _ClosingSocksServer {
  ServerSocket? _server;
  int port = 0;

  Future<void> start() async {
    _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    port = _server!.port;
    _server!.listen((client) => client.destroy());
  }

  Future<void> close() async {
    await _server?.close();
    _server = null;
  }
}
