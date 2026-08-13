// Decision-path tests for ChatService chunked file transfer: the send path
// must bring a cold WS link up before evaluating shouldUseChunkedTransfer,
// skip the bring-up entirely for sub-threshold files, and swallow bring-up
// failures back into the monolithic HTTP fallback.
import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/client/tor_websocket_client.dart';
import 'package:prysm/crypto/envelope.dart';
import 'package:prysm/crypto/identity.dart';
import 'package:prysm/crypto/ratchet/session_store.dart';
import 'package:prysm/database/messages.dart';
import 'package:prysm/services/chat_service.dart';
import 'package:prysm/services/side_channel_postman.dart';
import 'package:prysm/services/ws_connection_manager.dart';
import 'package:prysm/transport/outbound_ws_peer_link.dart';
import 'package:prysm/transport/transport_provider.dart';
import 'package:prysm/transport/ws_protocol.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/util/file_transfer_policy.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/pending_message_db_helper.dart';
import 'package:prysm/util/tor_lifecycle_state.dart';
import 'package:prysm/util/tor_runtime_gate.dart';
import 'package:prysm/util/tor_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<Database> _openPendingDb() async {
  final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
  await db.execute('DROP TABLE IF EXISTS pending_messages');
  await db.execute('''
    CREATE TABLE pending_messages(
      id TEXT PRIMARY KEY,
      senderId TEXT,
      receiverId TEXT,
      message TEXT,
      type TEXT,
      fileName TEXT,
      fileSize INTEGER,
      timestamp INTEGER,
      status TEXT,
      replyTo TEXT,
      viewOnce INTEGER DEFAULT 0,
      groupId TEXT,
      targetMemberId TEXT
    )
  ''');
  return db;
}

Future<Database> _openDbHelperDb() async {
  final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
  await db.execute('DROP TABLE IF EXISTS users');
  await db.execute('''
    CREATE TABLE users (
      id TEXT PRIMARY KEY,
      name TEXT,
      avatarUrl TEXT,
      avatarBase64 TEXT,
      customName TEXT,
      publicKeyPem TEXT,
      identityJson TEXT,
      ratchetScheme TEXT
    )
  ''');
  await RatchetSessionStore.ensureTable(db);
  await db.execute('''
    CREATE TABLE conversation_preferences (
      conversationId TEXT PRIMARY KEY,
      isPinned INTEGER NOT NULL DEFAULT 0,
      pinnedAt INTEGER,
      isArchived INTEGER NOT NULL DEFAULT 0,
      archivedAt INTEGER,
      disappearingTimerSeconds INTEGER
    )
  ''');
  return db;
}

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
      editedAt INTEGER,
      expiresAt INTEGER
    )
  ''');
  return db;
}

class _FakePostmanCall {
  _FakePostmanCall({
    required this.peerId,
    required this.payload,
    required this.timeout,
  });

  final String peerId;
  final Map<String, dynamic> payload;
  final Duration timeout;
}

class _FakePostman implements SideChannelPostman {
  final directCalls = <_FakePostmanCall>[];

  @override
  Future<void> postDirect({
    required String peerId,
    required Map<String, dynamic> payload,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    directCalls.add(
      _FakePostmanCall(peerId: peerId, payload: payload, timeout: timeout),
    );
  }

  @override
  Future<void> postGroup({
    required String targetMemberId,
    required Map<String, dynamic> payload,
    Duration timeout = const Duration(seconds: 30),
  }) async {}
}

/// A connected outbound link stub whose [TorWebSocketClient] advertises the
/// file-transfer capability, so registering it also populates the manager's
/// per-peer capability map the way a real handshake would.
class _CapableLink extends OutboundWsPeerLink {
  _CapableLink(String peerOnion)
      : super(TorWebSocketClient(peerOnion: peerOnion, socksPort: 9050)) {
    client.peerSupports = [wsFileTransferCapability];
  }

  final pushController = StreamController<Map<String, dynamic>>.broadcast();
  final sentOps = <String>[];

  @override
  bool get isConnected => true;

  @override
  Stream<Map<String, dynamic>> get onPushFrames => pushController.stream;

  @override
  Stream<List<int>> get onBinaryFrames => const Stream.empty();

  @override
  Future<void> close() async {}

  @override
  Future<Map<String, dynamic>> request(
    String op, {
    Map<String, dynamic>? payload,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    sentOps.add(op);
    if (op == 'file_transfer_begin' && payload != null) {
      return {'ok': true, 'transferId': payload['transferId']};
    }
    if (op == 'file_transfer_end' && payload != null) {
      return {'ok': true, 'transferId': payload['transferId']};
    }
    return {'ok': true};
  }

  @override
  Future<void> send(String op, {Map<String, dynamic>? payload}) async {
    sentOps.add(op);
  }

  @override
  Future<void> sendBytes(List<int> bytes) async {
    final frame = FileTransferChunkFrame.decode(bytes);
    pushController.add({
      'op': 'file_transfer_chunk_ack',
      'payload': {
        'transferId': frame.transferId,
        'chunkIndex': frame.chunkIndex,
      },
    });
  }

  @override
  Future<void> sendPing() async {}
}

const userId = 'me.onion';
// Lexically smaller than the fake local onion ('z'*56), so the manager's
// dial policy waits for an inbound link instead of dialing out over SOCKS.
const peerId = '0000000000000000000000000000000000000000000000000000000000000000.onion';

late Directory docsDir;
late Directory torDataDir;

late Database pendingDb;
late Database dbHelperDb;
late Database messagesDb;
late KeyManager keyManager;
late IdentityKeyPair peerKeyPair;

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;

    docsDir = Directory.systemTemp.createTempSync('chat_chunked_test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async {
        if (call.method == 'getApplicationDocumentsDirectory') {
          return docsDir.path;
        }
        return null;
      },
    );
  });

  tearDownAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    docsDir.deleteSync(recursive: true);
  });

  setUp(() async {
    pendingDb = await _openPendingDb();
    PendingMessageDbHelper.setDatabaseForTest(pendingDb);

    dbHelperDb = await _openDbHelperDb();
    DBHelper.setDatabaseForTest(dbHelperDb);

    messagesDb = await _openMessagesDb();
    MessagesDb.setDatabaseForTest(messagesDb);

    peerKeyPair = await IdentityKeyPair.generate();
    keyManager = KeyManager.fromIdentity(await IdentityKeyPair.generate());

    TorRuntimeGate.resetForTest();
    TorLifecycleNotifier.instance.update(TorLifecycleState.ready);

    torDataDir = Directory.systemTemp.createTempSync('chat_chunked_tor');
  });

  tearDown(() async {
    await pendingDb.close();
    PendingMessageDbHelper.setDatabaseForTest(null);

    await dbHelperDb.close();
    DBHelper.setDatabaseForTest(null);

    await messagesDb.close();
    MessagesDb.setDatabaseForTest(null);

    TorRuntimeGate.resetForTest();
    TransportProvider.resetForTest();
    torDataDir.deleteSync(recursive: true);
  });

  Future<ChatService> serviceWithPostman(_FakePostman postman) async {
    final service = ChatService(
      userId: userId,
      peerId: peerId,
      keyManager: keyManager,
      postman: postman,
    );
    addTearDown(service.dispose);
    service.peerIdentity = IdentityPublicKeys(
      signPublic: await peerKeyPair.signPublicKey,
      agreePublic: await peerKeyPair.agreePublicKey,
      fingerprint: 'test',
    );
    return service;
  }

  /// Registers a fake local onion so a bring-up attempt can resolve one.
  void writeLocalOnion() {
    Directory('${torDataDir.path}/hidden_service').createSync(recursive: true);
    File('${torDataDir.path}/hidden_service/hostname')
        .writeAsStringSync('${'z' * 56}.onion');
  }

  /// Queues one pending file message with a valid file envelope payload.
  Future<void> queueFileMessage(String id, int fileSize) async {
    final ciphertext =
        Uint8List.fromList(List<int>.generate(300, (i) => i % 251));
    final envelope = CryptoEnvelope.fileAead1(
      wrappedKey: {'ephemeralPub': 'abc'},
      nonce: Uint8List(12),
      ciphertext: ciphertext,
    );
    final peerPayload = CryptoEnvelope.encode(envelope);
    await MessagesDb.insertMessage({
      'id': id,
      'senderId': userId,
      'receiverId': peerId,
      'message': peerPayload,
      'type': 'file',
      'fileName': 'big.bin',
      'fileSize': fileSize,
      'timestamp': 1,
      'status': 'pending',
    }, notifyListeners: false);
    await PendingMessageDbHelper.insertPendingMessage({
      'id': id,
      'senderId': userId,
      'receiverId': peerId,
      'message': peerPayload,
      'type': 'file',
      'fileName': 'big.bin',
      'fileSize': fileSize,
      'timestamp': 1,
      'status': 'pending',
    });
  }

  /// A nudge stub that counts bring-up entries into the inbound wait and, when
  /// asked, registers a capable link there — the only deterministic way to
  /// complete prepareForFileTransfer on the real connection manager.
  ({int nudges, _CapableLink? link}) Function() nudgeThatRegisters(
    WsConnectionManager manager,
  ) {
    var nudges = 0;
    _CapableLink? link;
    manager.nudgePeerForInbound = (peer) async {
      nudges++;
      // Let _waitForInboundLink register its completer before the register
      // completes it; otherwise the registration races the waiter.
      await Future<void>.delayed(Duration.zero);
      link = _CapableLink(peer);
      manager.registerLinkForTest(peer, link!, outbound: true);
    };
    return () => (nudges: nudges, link: link);
  }

  test('sub-threshold file never brings the link up', () async {
    writeLocalOnion();
    TransportProvider.configure(
      TorManager(
        torPath: '/bin/false',
        dataDir: torDataDir.path,
        controlPassword: 'test-password',
      ),
    );
    final manager = TransportProvider.instance.wsManager;
    final observed = nudgeThatRegisters(manager);

    // A pending failure marks the peer; pinPeer (the first thing the bring-up
    // does) would clear it, so it surviving proves the bring-up never ran.
    manager.recordConnectFailureForTest(peerId, Exception('x'));
    expect(manager.retryDelayForTest(peerId), isNotNull);

    final postman = _FakePostman();
    final service = await serviceWithPostman(postman);
    const id = 'small-1';
    await queueFileMessage(id, FileTransferPolicy.chunkThresholdBytes - 1);

    final sent = service.onMessageStatus.firstWhere(
      (u) => u.messageId == id && u.status == 'sent',
    );
    service.startSendQueue();
    await sent.timeout(const Duration(seconds: 10));
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final state = observed();
    expect(state.nudges, 0, reason: 'bring-up must not run for sub-threshold');
    expect(state.link, isNull);
    expect(manager.retryDelayForTest(peerId), isNotNull,
        reason: 'bring-up would have pinned the peer and cleared the backoff');
    expect(postman.directCalls, hasLength(1));
    expect(postman.directCalls.single.payload['fileSize'],
        FileTransferPolicy.chunkThresholdBytes - 1);
  });

  test('cold link is brought up before the chunked decision', () async {
    writeLocalOnion();
    TransportProvider.configure(
      TorManager(
        torPath: '/bin/false',
        dataDir: torDataDir.path,
        controlPassword: 'test-password',
      ),
    );
    final manager = TransportProvider.instance.wsManager;
    final observed = nudgeThatRegisters(manager);

    final postman = _FakePostman();
    final service = await serviceWithPostman(postman);
    const id = 'big-1';
    await queueFileMessage(id, 2 * 1024 * 1024);

    final sent = service.onMessageStatus.firstWhere(
      (u) => u.messageId == id && u.status == 'sent',
    );
    service.startSendQueue();
    await sent.timeout(const Duration(seconds: 10));
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final state = observed();
    expect(state.nudges, 1, reason: 'bring-up must run before the decision');
    final link = state.link;
    expect(link, isNotNull);
    expect(link!.sentOps, contains('file_transfer_begin'),
        reason: 'chunked path must be chosen once the link is up');
    expect(postman.directCalls, isEmpty,
        reason: 'chunked success must not fall back to HTTP');
  });

  test('a throwing bring-up falls back to monolithic without propagating',
      () async {
    // No local onion file: prepareForFileTransfer throws
    // 'Local onion address not available' from the ensureConnected path.
    TransportProvider.configure(
      TorManager(
        torPath: '/bin/false',
        dataDir: torDataDir.path,
        controlPassword: 'test-password',
      ),
    );
    final manager = TransportProvider.instance.wsManager;
    final observed = nudgeThatRegisters(manager);

    final postman = _FakePostman();
    final service = await serviceWithPostman(postman);
    const id = 'throw-1';
    await queueFileMessage(id, 2 * 1024 * 1024);

    final sent = service.onMessageStatus.firstWhere(
      (u) => u.messageId == id && u.status == 'sent',
    );
    service.startSendQueue();
    // Completing proves the send queue survived the bring-up throw.
    await sent.timeout(const Duration(seconds: 10));
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(observed().nudges, 0);
    expect(postman.directCalls, hasLength(1));
    expect(postman.directCalls.single.payload['type'], 'file');
  });
}
