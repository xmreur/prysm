import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/util/group_sender_index_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<Database> _openTestDb() async {
  final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
  await GroupSenderIndexStore.ensureTable(db);
  return db;
}

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  const groupId = 'g1';
  const senderId = 'me.onion';

  late Database db;

  setUp(() async {
    db = await _openTestDb();
    DBHelper.setDatabaseForTest(db);
  });

  tearDown(() async {
    // Claim ownership is process-global: a claim left by one case would
    // refuse the same triple in the next, so it must be cleared between
    // cases.
    GroupSenderIndexStore.resetForTest();
    await db.close();
    DBHelper.setDatabaseForTest(null);
  });

  test('nextIndex returns monotonically increasing values', () async {
    expect(
      await GroupSenderIndexStore.nextIndex(groupId: groupId, senderId: senderId),
      0,
    );
    expect(
      await GroupSenderIndexStore.nextIndex(groupId: groupId, senderId: senderId),
      1,
    );
    expect(
      await GroupSenderIndexStore.nextIndex(groupId: groupId, senderId: senderId),
      2,
    );
  });

  test('concurrent nextIndex calls get distinct indices', () async {
    const parallelCalls = 8;
    final results = await Future.wait(
      List.generate(
        parallelCalls,
        (_) => GroupSenderIndexStore.nextIndex(
          groupId: groupId,
          senderId: senderId,
        ),
      ),
    );

    expect(results.toSet(), hasLength(parallelCalls));
    expect(results.toSet(), {for (var i = 0; i < parallelCalls; i++) i});
  });

  test('claimInboundIndex grants a fresh claim; an unresolved claim held by '
      'this process refuses a second claim of the same triple', () async {
    expect(
      await GroupSenderIndexStore.claimInboundIndex(
        groupId: groupId,
        senderId: senderId,
        index: 3,
      ),
      isTrue,
    );
    // Same triple while unresolved and owned by this process: refused — a
    // concurrent delivery of the same envelope is being processed right now,
    // and two copies under different transport ids must not both be stored.
    expect(
      await GroupSenderIndexStore.claimInboundIndex(
        groupId: groupId,
        senderId: senderId,
        index: 3,
      ),
      isFalse,
    );
  });

  test('an unresolved row left by a previous process is claimed successfully',
      () async {
    // Exactly what a kill between claim and store leaves behind: an
    // unresolved row whose owner process no longer exists. Inserting it
    // directly into the database (bypassing claimInboundIndex) is the only
    // honest simulation — this process never claimed it, so ownership says
    // the owner is dead and the claim is taken over whenever the retry
    // arrives, no clock involved.
    await db.insert('group_inbound_seen', {
      'groupId': groupId,
      'senderId': senderId,
      'msgIndex': 3,
      'resolved': 0,
    });
    expect(
      await GroupSenderIndexStore.claimInboundIndex(
        groupId: groupId,
        senderId: senderId,
        index: 3,
      ),
      isTrue,
    );
    // The taken-over claim is now owned by this process: a concurrent
    // duplicate is refused again.
    expect(
      await GroupSenderIndexStore.claimInboundIndex(
        groupId: groupId,
        senderId: senderId,
        index: 3,
      ),
      isFalse,
    );
  });

  test('a resolved triple is refused for good, and releaseInboundIndex on it '
      'is a no-op', () async {
    expect(
      await GroupSenderIndexStore.claimInboundIndex(
        groupId: groupId,
        senderId: senderId,
        index: 7,
      ),
      isTrue,
    );
    await GroupSenderIndexStore.resolveInboundIndex(
      groupId: groupId,
      senderId: senderId,
      index: 7,
    );
    expect(
      await GroupSenderIndexStore.claimInboundIndex(
        groupId: groupId,
        senderId: senderId,
        index: 7,
      ),
      isFalse,
    );
    // A later failure must never remove a resolved row: release only
    // affects unresolved claims.
    await GroupSenderIndexStore.releaseInboundIndex(
      groupId: groupId,
      senderId: senderId,
      index: 7,
    );
    expect(
      await GroupSenderIndexStore.claimInboundIndex(
        groupId: groupId,
        senderId: senderId,
        index: 7,
      ),
      isFalse,
    );
    // The resolved row survived the release.
    final rows = await db.query('group_inbound_seen');
    expect(rows, hasLength(1));
    expect(rows.single['resolved'], 1);
  });

  test('releaseInboundIndex on an unresolved claim makes the triple '
      'claimable again', () async {
    expect(
      await GroupSenderIndexStore.claimInboundIndex(
        groupId: groupId,
        senderId: senderId,
        index: 7,
      ),
      isTrue,
    );
    // A failed store releases the claim; the sender's retry can then claim
    // and store the message instead of being dropped as a duplicate.
    await GroupSenderIndexStore.releaseInboundIndex(
      groupId: groupId,
      senderId: senderId,
      index: 7,
    );
    expect(
      await GroupSenderIndexStore.claimInboundIndex(
        groupId: groupId,
        senderId: senderId,
        index: 7,
      ),
      isTrue,
    );
  });

  test('claimInboundIndex accepts out-of-order first sightings and rejects '
      'exact duplicates', () async {
    expect(
      await GroupSenderIndexStore.claimInboundIndex(
        groupId: groupId,
        senderId: senderId,
        index: 3,
      ),
      isTrue,
    );
    await GroupSenderIndexStore.resolveInboundIndex(
      groupId: groupId,
      senderId: senderId,
      index: 3,
    );
    // An out-of-order first sighting (2 < 3, never seen) is accepted.
    expect(
      await GroupSenderIndexStore.claimInboundIndex(
        groupId: groupId,
        senderId: senderId,
        index: 2,
      ),
      isTrue,
    );
    await GroupSenderIndexStore.resolveInboundIndex(
      groupId: groupId,
      senderId: senderId,
      index: 2,
    );
    // Exact duplicates are rejected, regardless of order.
    expect(
      await GroupSenderIndexStore.claimInboundIndex(
        groupId: groupId,
        senderId: senderId,
        index: 2,
      ),
      isFalse,
    );
    expect(
      await GroupSenderIndexStore.claimInboundIndex(
        groupId: groupId,
        senderId: senderId,
        index: 3,
      ),
      isFalse,
    );
    // A higher first sighting is new.
    expect(
      await GroupSenderIndexStore.claimInboundIndex(
        groupId: groupId,
        senderId: senderId,
        index: 4,
      ),
      isTrue,
    );
  });

  test('claimInboundIndex seen-set is scoped per (groupId, senderId)',
      () async {
    const otherSender = 'peer.onion';
    const otherGroup = 'g2';
    expect(
      await GroupSenderIndexStore.claimInboundIndex(
        groupId: groupId,
        senderId: senderId,
        index: 7,
      ),
      isTrue,
    );
    await GroupSenderIndexStore.resolveInboundIndex(
      groupId: groupId,
      senderId: senderId,
      index: 7,
    );
    // Same group, different sender: the same index is unaffected.
    expect(
      await GroupSenderIndexStore.claimInboundIndex(
        groupId: groupId,
        senderId: otherSender,
        index: 7,
      ),
      isTrue,
    );
    await GroupSenderIndexStore.resolveInboundIndex(
      groupId: groupId,
      senderId: otherSender,
      index: 7,
    );
    // Same sender, different group: the same index is unaffected.
    expect(
      await GroupSenderIndexStore.claimInboundIndex(
        groupId: otherGroup,
        senderId: senderId,
        index: 7,
      ),
      isTrue,
    );
    await GroupSenderIndexStore.resolveInboundIndex(
      groupId: otherGroup,
      senderId: senderId,
      index: 7,
    );
    // The original (groupId, senderId) pair still rejects its exact
    // duplicate, but a lower unseen index is new (no watermark).
    expect(
      await GroupSenderIndexStore.claimInboundIndex(
        groupId: groupId,
        senderId: senderId,
        index: 7,
      ),
      isFalse,
    );
    expect(
      await GroupSenderIndexStore.claimInboundIndex(
        groupId: groupId,
        senderId: senderId,
        index: 6,
      ),
      isTrue,
    );
    // Outbound state is separate: inbound claims never advance the outbound
    // nextIndex counter.
    expect(
      await GroupSenderIndexStore.nextIndex(
        groupId: groupId,
        senderId: senderId,
      ),
      0,
    );
  });

  test('resetForGroup clears the inbound seen-set too', () async {
    // A resolved row...
    expect(
      await GroupSenderIndexStore.claimInboundIndex(
        groupId: groupId,
        senderId: senderId,
        index: 7,
      ),
      isTrue,
    );
    await GroupSenderIndexStore.resolveInboundIndex(
      groupId: groupId,
      senderId: senderId,
      index: 7,
    );
    // ...and an in-flight (unresolved) claim are both cleared.
    expect(
      await GroupSenderIndexStore.claimInboundIndex(
        groupId: groupId,
        senderId: senderId,
        index: 8,
      ),
      isTrue,
    );
    await GroupSenderIndexStore.resetForGroup(groupId);
    // The exact same triples are accepted again after the reset.
    expect(
      await GroupSenderIndexStore.claimInboundIndex(
        groupId: groupId,
        senderId: senderId,
        index: 7,
      ),
      isTrue,
    );
    expect(
      await GroupSenderIndexStore.claimInboundIndex(
        groupId: groupId,
        senderId: senderId,
        index: 8,
      ),
      isTrue,
    );
  });

  test('resetForGroup drops in-memory ownership: a dead owner\u0027s row for '
      'a reset group is still taken over', () async {
    // This process owns an in-flight claim for the triple...
    expect(
      await GroupSenderIndexStore.claimInboundIndex(
        groupId: groupId,
        senderId: senderId,
        index: 8,
      ),
      isTrue,
    );
    await GroupSenderIndexStore.resetForGroup(groupId);
    // ...then a different process crashes mid-claim on the same triple (an
    // unresolved row inserted directly, exactly what the kill leaves).
    await db.insert('group_inbound_seen', {
      'groupId': groupId,
      'senderId': senderId,
      'msgIndex': 8,
      'resolved': 0,
    });
    // A stale in-memory key from before the reset must not refuse the
    // takeover: the reset dropped the group's ownership.
    expect(
      await GroupSenderIndexStore.claimInboundIndex(
        groupId: groupId,
        senderId: senderId,
        index: 8,
      ),
      isTrue,
    );
  });
}
