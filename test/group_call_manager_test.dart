import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/crypto/identity.dart';
import 'package:prysm/database/blocked_users_db.dart';
import 'package:prysm/database/call_logs_db.dart';
import 'package:prysm/database/messages.dart';
import 'package:prysm/models/group.dart';
import 'package:prysm/services/block_service.dart';
import 'package:prysm/services/call/audio_engine.dart';
import 'package:prysm/services/call/call_foreground_session.dart';
import 'package:prysm/services/call/call_manager.dart';
import 'package:prysm/services/call/call_signaling_notifier.dart';
import 'package:prysm/services/call/call_transport.dart';
import 'package:prysm/services/call/group_audio_engine.dart';
import 'package:prysm/services/call/group_call_manager.dart';
import 'package:prysm/services/call/group_call_snapshot.dart';
import 'package:prysm/services/call/group_call_session.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/local_onion_address.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const local = 'local.onion';
const alice = 'alice.onion';
const bob = 'bob.onion';
const groupId = 'group-1';

void main() {
  // MessagesDb.insertMessage reaches the services binding on the way to the
  // search index.
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeTransport transport;
  late _FakeKeyResolver keyResolver;
  late KeyManager keyManager;
  late KeyManager peerKeyManager;
  late CallSignalingNotifier notifier;
  late GroupCallManager manager;
  late _RecordingForegroundSession foreground;
  late List<GroupCallMember> roster;
  late List<_FakeGroupAudio> audios;
  late Database messagesDb;

  late IdentityPublicKeys localKeys;
  late IdentityPublicKeys peerKeys;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    final db = await databaseFactory.openDatabase(
      '${inMemoryDatabasePath}_group_call_${DateTime.now().microsecondsSinceEpoch}',
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, _) async {
          await BlockedUsersDb.createTable(db);
          await CallLogsDb.createTable(db);
        },
      ),
    );
    DBHelper.setDatabaseForTest(db);
    await BlockService.instance.init();
    LocalOnionAddress.provider = () => local;

    // The end-of-call summary goes into the messages database, which is a
    // separate opener from DBHelper's.
    messagesDb = await databaseFactory.openDatabase(
      '${inMemoryDatabasePath}_group_call_msgs_${DateTime.now().microsecondsSinceEpoch}',
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, _) async {
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
        },
      ),
    );
    MessagesDb.setDatabaseForTest(messagesDb);

    final localId = await IdentityKeyPair.generate();
    final peerId = await IdentityKeyPair.generate();
    keyManager = KeyManager.fromIdentity(localId);
    peerKeyManager = KeyManager.fromIdentity(peerId);
    localKeys = IdentityPublicKeys(
      signPublic: await localId.signPublicKey,
      agreePublic: await localId.agreePublicKey,
      fingerprint: 'local',
    );
    peerKeys = IdentityPublicKeys(
      signPublic: await peerId.signPublicKey,
      agreePublic: await peerId.agreePublicKey,
      fingerprint: 'peer',
    );

    roster = const [
      GroupCallMember(onion: local, role: GroupRole.member, muted: false),
      GroupCallMember(onion: alice, role: GroupRole.owner, muted: false),
      GroupCallMember(onion: bob, role: GroupRole.member, muted: false),
    ];
    audios = [];
    transport = _FakeTransport();
    keyResolver = _FakeKeyResolver(peerKeys);
    notifier = CallSignalingNotifier();
    CallSignalingNotifier.testInstance = notifier;
    CallManager.resetForTest();
    GroupCallManager.resetForTest();
    foreground = _RecordingForegroundSession();
    CallForegroundSession.testOverride = foreground;
    manager = _buildManager(
      keyManager: keyManager,
      transport: transport,
      keyResolver: keyResolver,
      roster: () => roster,
      audios: audios,
    );
    manager.start();
  });

  tearDown(() {
    CallSignalingNotifier.testInstance = null;
    // Stops in-flight teardown work from reaching the real foreground session
    // once the test override is cleared below.
    manager.dispose();
    GroupCallManager.resetForTest();
    CallManager.resetForTest();
    LocalOnionAddress.provider = null;
    DBHelper.setDatabaseForTest(null);
    MessagesDb.setDatabaseForTest(null);
  });

  /// A `group_call_offer` from [from] as the initiator would send it.
  Future<void> applyInboundOffer({
    String from = alice,
    String callId = 'inbound-call',
    List<String> members = const [alice, local, bob],
  }) async {
    final initiator = GroupCallSession.createOutbound(
      callId: callId,
      sessionId: 42,
      groupId: groupId,
      members: members,
      localOnion: from,
    );
    notifier.applyInbound(from, 'group_call_offer', {
      'callId': callId,
      'groupId': groupId,
      'sessionId': 42,
      'members': members,
      'wrappedKey': await initiator.wrapKeyForPeer(localKeys, peerKeyManager),
    });
    await _pump();
  }

  test('startGroupCall offers to every other member and rings', () async {
    await manager.startGroupCall(groupId);

    final offers = transport.sent.where((f) => f.op == 'group_call_offer');
    expect(offers.map((f) => f.peerOnion).toSet(), {alice, bob});
    for (final offer in offers) {
      expect(offer.payload['groupId'], groupId);
      expect(offer.payload['members'], [local, alice, bob]);
      expect(offer.payload['wrappedKey'], isA<String>());
    }
    expect(manager.snapshot.state, CallState.ringing);
    expect(manager.snapshot.joined, {local});
    expect(manager.isBusy, isTrue);
    // The 1:1 manager must see the device as occupied.
    expect(CallManager.deviceBusy, isTrue);
  });

  test('a join activates audio and later joins/leaves move the roster',
      () async {
    await manager.startGroupCall(groupId);
    final callId = manager.snapshot.callId;

    notifier.applyInbound(alice, 'group_call_join', {
      'callId': callId,
      'groupId': groupId,
    });
    await _pump();

    expect(manager.snapshot.state, CallState.active);
    expect(manager.snapshot.joined, {local, alice});
    expect(audios, hasLength(1));
    expect(audios.single.started, isTrue);
    expect(audios.single.targets, {alice});

    notifier.applyInbound(bob, 'group_call_join', {
      'callId': callId,
      'groupId': groupId,
    });
    await _pump();
    expect(manager.snapshot.joined, {local, alice, bob});
    expect(audios.single.targets, {alice, bob});

    notifier.applyInbound(alice, 'group_call_leave', {
      'callId': callId,
      'groupId': groupId,
    });
    await _pump();
    expect(manager.snapshot.state, CallState.active);
    expect(manager.snapshot.joined, {local, bob});
    expect(audios.single.targets, {bob});

    // The last remote leaving ends the call locally.
    notifier.applyInbound(bob, 'group_call_leave', {
      'callId': callId,
      'groupId': groupId,
    });
    await _waitFor(() => manager.snapshot.state == CallState.idle);
    expect(manager.isBusy, isFalse);
    expect(audios.single.stopped, isTrue);
  });

  test('a leave from a member that never joined does not end the call',
      () async {
    await manager.startGroupCall(groupId);
    final callId = manager.snapshot.callId;

    notifier.applyInbound(alice, 'group_call_join', {
      'callId': callId,
      'groupId': groupId,
    });
    await _pump();
    expect(manager.snapshot.state, CallState.active);

    // bob replies leave because it is busy elsewhere.
    notifier.applyInbound(bob, 'group_call_leave', {
      'callId': callId,
      'groupId': groupId,
    });
    await _pump();
    expect(manager.snapshot.state, CallState.active);
    expect(manager.snapshot.joined, {local, alice});
  });

  test('inbound offer rings, and joining answers every frozen member',
      () async {
    await applyInboundOffer();

    expect(manager.snapshot.state, CallState.incoming);
    expect(manager.snapshot.groupId, groupId);
    expect(manager.snapshot.members, [alice, local, bob]);
    expect(manager.snapshot.joined, {alice});

    await manager.join();

    final joins = transport.sent.where((f) => f.op == 'group_call_join');
    expect(joins.map((f) => f.peerOnion).toSet(), {alice, bob});
    expect(manager.snapshot.state, CallState.active);
    expect(manager.snapshot.joined, {alice, local});
  });

  test('dismissing keeps the banner, and a late join still works', () async {
    await applyInboundOffer();
    await manager.dismissIncoming();

    // No op goes out on decline: the call keeps running for the others.
    expect(transport.sent.where((f) => f.op == 'group_call_leave'), isEmpty);
    expect(manager.isBusy, isFalse);
    expect(manager.snapshot.showJoinBannerFor(groupId), isTrue);
    expect(manager.snapshot.showJoinBannerFor('other-group'), isFalse);
    expect(foreground.lastActive, isFalse);

    await manager.join();
    expect(manager.snapshot.state, CallState.active);
    expect(manager.snapshot.joined, {alice, local});
    expect(
      transport.sent
          .where((f) => f.op == 'group_call_join')
          .map((f) => f.peerOnion)
          .toSet(),
      {alice, bob},
    );
  });

  test('the banner clears when the last participant leaves', () async {
    await applyInboundOffer();
    await manager.dismissIncoming();

    notifier.applyInbound(alice, 'group_call_leave', {
      'callId': 'inbound-call',
      'groupId': groupId,
    });
    await _waitFor(() => manager.snapshot.callId == null);

    expect(manager.snapshot.showJoinBannerFor(groupId), isFalse);
  });

  test('ring timeout with nobody joining leaves and logs the call', () async {
    final quick = _buildManager(
      keyManager: keyManager,
      transport: transport,
      keyResolver: keyResolver,
      roster: () => roster,
      audios: audios,
      ringTimeout: const Duration(milliseconds: 20),
    );
    addTearDown(quick.dispose);
    quick.start();

    await quick.startGroupCall(groupId);
    final callId = quick.snapshot.callId;
    expect(quick.snapshot.state, CallState.ringing);

    await _waitFor(() => quick.snapshot.state == CallState.idle);
    expect(
      transport.sent
          .where((f) => f.op == 'group_call_leave')
          .map((f) => f.peerOnion)
          .toSet(),
      {alice, bob},
    );
    final logs = await CallLogsDb.getLogs();
    final log = logs.firstWhere((l) => l.callId == callId);
    expect(log.status, CallLogStatus.missed);
    expect(log.groupId, groupId);
    expect(log.peerOnion, groupId);
  });

  test('an inbound offer while a 1:1 call is up replies leave', () async {
    CallManager.configure(
      keyManager: keyManager,
      transport: _FakeTransport(),
      keyResolver: keyResolver,
      audioFactory: ({required session, required onSendFrame}) =>
          _NoopCallAudio(),
    );
    final oneToOne = CallManager.instance;
    oneToOne.start();
    await oneToOne.startCall('peer.onion');
    expect(oneToOne.isBusy, isTrue);

    await applyInboundOffer();

    expect(manager.snapshot.state, CallState.idle);
    expect(
      transport.sent
          .where((f) => f.op == 'group_call_leave')
          .map((f) => f.peerOnion),
      [alice],
    );
  });

  test('a group call in progress blocks a 1:1 call', () async {
    await manager.startGroupCall(groupId);
    final oneToOneTransport = _FakeTransport();
    CallManager.configure(
      keyManager: keyManager,
      transport: oneToOneTransport,
      keyResolver: keyResolver,
      audioFactory: ({required session, required onSendFrame}) =>
          _NoopCallAudio(),
    );
    final oneToOne = CallManager.instance;
    oneToOne.start();

    await oneToOne.startCall('peer.onion');

    expect(oneToOne.snapshot.state, CallState.idle);
    expect(oneToOneTransport.sent, isEmpty);
  });

  test('a moderation-muted member joins listen-only and cannot unmute',
      () async {
    roster = const [
      GroupCallMember(onion: local, role: GroupRole.member, muted: true),
      GroupCallMember(onion: alice, role: GroupRole.owner, muted: false),
      GroupCallMember(onion: bob, role: GroupRole.member, muted: false),
    ];
    await applyInboundOffer();
    await manager.join();

    expect(manager.snapshot.listenOnly, isTrue);
    expect(manager.snapshot.localMuted, isTrue);
    expect(audios.single.listenOnly, isTrue);

    await manager.toggleMute();
    expect(manager.snapshot.localMuted, isTrue);
    expect(transport.sent.where((f) => f.op == 'group_call_mute'), isEmpty);
  });

  test('audio frames from a moderation-muted member are dropped', () async {
    roster = const [
      GroupCallMember(onion: local, role: GroupRole.member, muted: false),
      GroupCallMember(onion: alice, role: GroupRole.owner, muted: true),
      GroupCallMember(onion: bob, role: GroupRole.member, muted: false),
    ];
    await applyInboundOffer();
    await manager.join();
    notifier.applyInbound(bob, 'group_call_join', {
      'callId': 'inbound-call',
      'groupId': groupId,
    });
    await _pump();

    transport.pushBinary(alice, [1, 2, 3]);
    transport.pushBinary(bob, [4, 5, 6]);
    await _pump();

    expect(audios.single.received.map((r) => r.peer), [bob]);
  });

  test('toggleMute fans out to the joined participants', () async {
    await manager.startGroupCall(groupId);
    notifier.applyInbound(alice, 'group_call_join', {
      'callId': manager.snapshot.callId,
      'groupId': groupId,
    });
    await _pump();

    await manager.toggleMute();

    final mutes = transport.sent.where((f) => f.op == 'group_call_mute');
    expect(mutes.map((f) => f.peerOnion), [alice]);
    expect(mutes.single.payload['muted'], isTrue);
    expect(manager.snapshot.localMuted, isTrue);
    expect(audios.single.muted, isTrue);
  });

  test('a participant mute is reflected in the snapshot', () async {
    await manager.startGroupCall(groupId);
    final callId = manager.snapshot.callId;
    notifier.applyInbound(alice, 'group_call_join', {
      'callId': callId,
      'groupId': groupId,
    });
    await _pump();

    notifier.applyInbound(alice, 'group_call_mute', {
      'callId': callId,
      'groupId': groupId,
      'muted': true,
    });
    await _pump();
    expect(manager.snapshot.peerMuted[alice], isTrue);
  });

  test('an offer for a group we are not in is ignored', () async {
    await applyInboundOffer(members: const [alice, bob]);
    expect(manager.snapshot.state, CallState.idle);
    expect(manager.snapshot.callId, isNull);
  });

  test('an offer from a non-member is ignored', () async {
    await applyInboundOffer(
      from: 'stranger.onion',
      members: const ['stranger.onion', local],
    );
    expect(manager.snapshot.state, CallState.idle);
  });

  test('inbound offer flood from one sender is rate-limited', () async {
    for (var i = 0; i < GroupCallManager.maxInboundOffersPerWindow + 3; i++) {
      await applyInboundOffer(callId: 'flood-$i');
      await manager.leave();
    }
    final offersAccepted = transport.sent
        .where((f) => f.op == 'group_call_leave')
        .map((f) => f.payload['callId'])
        .toSet();
    // Each accepted offer produces one fan-out leave on our own leave().
    expect(
      offersAccepted.length,
      GroupCallManager.maxInboundOffersPerWindow,
    );
  });

  test('a peer disconnect is treated as a leave', () async {
    await manager.startGroupCall(groupId);
    notifier.applyInbound(alice, 'group_call_join', {
      'callId': manager.snapshot.callId,
      'groupId': groupId,
    });
    await _pump();
    expect(manager.snapshot.state, CallState.active);

    manager.handlePeerDisconnected(alice);
    await _waitFor(() => manager.snapshot.state == CallState.idle);
    expect(manager.snapshot.state, CallState.idle);
  });

  test('leaving fans out leave and logs a completed call', () async {
    await manager.startGroupCall(groupId);
    final callId = manager.snapshot.callId;
    notifier.applyInbound(alice, 'group_call_join', {
      'callId': callId,
      'groupId': groupId,
    });
    await _pump();

    await manager.leave();

    expect(
      transport.sent
          .where((f) => f.op == 'group_call_leave')
          .map((f) => f.peerOnion)
          .toSet(),
      {alice, bob},
    );
    final log = (await CallLogsDb.getLogs())
        .firstWhere((l) => l.callId == callId);
    expect(log.status, CallLogStatus.completed);
    expect(log.groupId, groupId);
    // The summary lands in the group timeline, not a 1:1 thread. The insert is
    // fire-and-forget off the teardown path, so poll for it.
    var rows = const <Map<String, Object?>>[];
    for (var attempt = 0; attempt < 100 && rows.isEmpty; attempt++) {
      rows = await messagesDb
          .query('messages', where: 'type = ?', whereArgs: ['call']);
      if (rows.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }
    expect(rows, hasLength(1));
    expect(rows.single['groupId'], groupId);
  });
}

GroupCallManager _buildManager({
  required KeyManager keyManager,
  required _FakeTransport transport,
  required _FakeKeyResolver keyResolver,
  required List<GroupCallMember> Function() roster,
  required List<_FakeGroupAudio> audios,
  Duration ringTimeout = GroupCallManager.defaultRingTimeout,
}) {
  return GroupCallManager(
    keyManager: keyManager,
    transport: transport,
    keyResolver: keyResolver,
    loadRoster: (_) async => roster(),
    senderRefused: (_) async => false,
    ringTimeout: ringTimeout,
    audioFactory: ({
      required session,
      required onSendFrame,
      dropIncomingFrom,
    }) {
      final audio = _FakeGroupAudio(dropIncomingFrom: dropIncomingFrom);
      audios.add(audio);
      return audio;
    },
  );
}

Future<void> _pump() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Future<void> _waitFor(bool Function() predicate) async {
  for (var i = 0; i < 200; i++) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  throw StateError('condition never became true');
}

class _ReceivedFrame {
  _ReceivedFrame(this.peer, this.bytes);
  final String peer;
  final Uint8List bytes;
}

class _FakeGroupAudio implements GroupCallAudio {
  _FakeGroupAudio({this.dropIncomingFrom});

  final bool Function(String peerOnion)? dropIncomingFrom;
  final received = <_ReceivedFrame>[];
  final remotes = <String>{};
  Set<String> targets = {};
  bool started = false;
  bool stopped = false;
  bool listenOnly = false;
  bool muted = false;

  @override
  bool get isRunning => started && !stopped;

  @override
  bool get isMuted => muted;

  @override
  Future<bool> start({required bool listenOnly}) async {
    started = true;
    this.listenOnly = listenOnly;
    return true;
  }

  @override
  Future<void> stop() async {
    stopped = true;
  }

  @override
  void handleIncoming(String peerOnion, Uint8List encryptedFrame) {
    if (dropIncomingFrom?.call(peerOnion) == true) return;
    received.add(_ReceivedFrame(peerOnion, encryptedFrame));
  }

  @override
  void setMuted(bool muted) => this.muted = muted;

  @override
  void setSpeakAllowed(bool allowed) => listenOnly = !allowed;

  @override
  void setSendTargets(Set<String> peers) => targets = peers;

  @override
  void addRemote(String peerOnion) => remotes.add(peerOnion);

  @override
  void removeRemote(String peerOnion) => remotes.remove(peerOnion);
}

class _NoopCallAudio implements CallAudio {
  @override
  bool get isRunning => true;

  @override
  bool get isMuted => false;

  @override
  Future<bool> start() async => true;

  @override
  Future<void> stop() async {}

  @override
  void handleIncoming(Uint8List encryptedFrame) {}

  @override
  void setMuted(bool muted) {}
}

class _SentFrame {
  _SentFrame(this.peerOnion, this.op, this.payload);
  final String peerOnion;
  final String op;
  final Map<String, dynamic> payload;
}

class _FakeTransport implements CallTransport {
  final sent = <_SentFrame>[];
  final _binary = <String, StreamController<List<int>>>{};

  @override
  Future<void> ensureConnected(String peerOnion) async {}

  @override
  Future<void> send(
    String peerOnion,
    String op,
    Map<String, dynamic> payload,
  ) async {
    sent.add(_SentFrame(peerOnion, op, Map<String, dynamic>.from(payload)));
  }

  @override
  Future<void> sendBytes(String peerOnion, Uint8List bytes) async {}

  @override
  void pinPeer(String peerOnion) {}

  @override
  void unpinPeer(String peerOnion) {}

  @override
  Stream<List<int>> binaryFramesFor(String peerOnion) =>
      (_binary[peerOnion] ??= StreamController<List<int>>.broadcast()).stream;

  void pushBinary(String peerOnion, List<int> bytes) {
    _binary[peerOnion]?.add(bytes);
  }
}

class _FakeKeyResolver implements CallKeyResolver {
  _FakeKeyResolver(this.keys);
  final IdentityPublicKeys keys;

  @override
  Future<IdentityPublicKeys?> resolve(String peerOnion) async => keys;
}

class _RecordingForegroundSession implements CallForegroundSessionPort {
  final syncCalls = <CallSnapshot>[];
  bool lastActive = false;

  @override
  bool get inCall => lastActive;

  @override
  Future<void> sync(CallSnapshot snapshot, {CallSnapshot? previous}) async {
    syncCalls.add(snapshot);
    lastActive = snapshot.isInCall;
  }

  @override
  Future<void> onAppLifecycleChanged(AppLifecycleState state) async {}
}
