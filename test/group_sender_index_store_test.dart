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

  // Mirrors GroupSenderIndexStore._seenRetained (private by design): the
  // retention bound is part of the store's contract, so the operational
  // limit test pins the exact number the store uses.
  const seenRetained = 256;

  test('the seen-set is bounded: resolving past the retention bound prunes '
      'to _seenRetained rows and raises the floor', () async {
    for (var i = 0; i < seenRetained + 50; i++) {
      expect(
        await GroupSenderIndexStore.claimInboundIndex(
          groupId: groupId,
          senderId: senderId,
          index: i,
        ),
        isTrue,
      );
      await GroupSenderIndexStore.resolveInboundIndex(
        groupId: groupId,
        senderId: senderId,
        index: i,
      );
    }

    // Exactly the retained window survives; the 50 oldest resolved rows
    // were pruned into the floor.
    final rows = await db.query('group_inbound_seen');
    expect(rows, hasLength(seenRetained));
    final floor = await db.query('group_inbound_floor');
    expect(floor, hasLength(1));
    expect(floor.single['prunedBelow'], 50);

    // The total cannot grow further: resolving more indices keeps the table
    // at the bound and pushes the floor forward one-for-one.
    for (var i = seenRetained + 50; i < seenRetained + 100; i++) {
      expect(
        await GroupSenderIndexStore.claimInboundIndex(
          groupId: groupId,
          senderId: senderId,
          index: i,
        ),
        isTrue,
      );
      await GroupSenderIndexStore.resolveInboundIndex(
        groupId: groupId,
        senderId: senderId,
        index: i,
      );
    }
    expect(await db.query('group_inbound_seen'), hasLength(seenRetained));
    final floorAfter = await db.query('group_inbound_floor');
    expect(floorAfter.single['prunedBelow'], 100);
  });

  test('a pruned index is refused: never re-accepted', () async {
    for (var i = 0; i < seenRetained + 10; i++) {
      expect(
        await GroupSenderIndexStore.claimInboundIndex(
          groupId: groupId,
          senderId: senderId,
          index: i,
        ),
        isTrue,
      );
      await GroupSenderIndexStore.resolveInboundIndex(
        groupId: groupId,
        senderId: senderId,
        index: i,
      );
    }

    // Indices 0..9 were pruned and the floor now stands at 10.
    final floor = await db.query('group_inbound_floor');
    expect(floor.single['prunedBelow'], 10);
    // The pruned row is gone — it cannot come back as a fresh claim.
    final prunedRow = await db.query(
      'group_inbound_seen',
      where: 'groupId = ? AND senderId = ? AND msgIndex = ?',
      whereArgs: [groupId, senderId, 0],
    );
    expect(prunedRow, isEmpty);
    // The replay of a captured pruned envelope is refused by the floor.
    expect(
      await GroupSenderIndexStore.claimInboundIndex(
        groupId: groupId,
        senderId: senderId,
        index: 0,
      ),
      isFalse,
    );
    // At the floor edge too, and a still-retained resolved index is
    // refused as an exact duplicate as before.
    expect(
      await GroupSenderIndexStore.claimInboundIndex(
        groupId: groupId,
        senderId: senderId,
        index: 9,
      ),
      isFalse,
    );
    expect(
      await GroupSenderIndexStore.claimInboundIndex(
        groupId: groupId,
        senderId: senderId,
        index: 10,
      ),
      isFalse,
    );
  });

  test('an unseen index above the floor is still accepted out of order',
      () async {
    // Deliver every index 0..seenRetained+19 except 257, which arrives
    // late (the retry path re-sends with its original index).
    for (var i = 0; i < seenRetained + 20; i++) {
      if (i == 257) continue;
      expect(
        await GroupSenderIndexStore.claimInboundIndex(
          groupId: groupId,
          senderId: senderId,
          index: i,
        ),
        isTrue,
      );
      await GroupSenderIndexStore.resolveInboundIndex(
        groupId: groupId,
        senderId: senderId,
        index: i,
      );
    }

    // 275 resolved > 256: the 19 oldest were pruned, floor = 19. The
    // unseen 257 sits far above it.
    final floor = await db.query('group_inbound_floor');
    expect(floor.single['prunedBelow'], 19);
    // The late first sighting is still a message, not a replay: the floor
    // must not reintroduce the old watermark's censoring within the window.
    expect(
      await GroupSenderIndexStore.claimInboundIndex(
        groupId: groupId,
        senderId: senderId,
        index: 257,
      ),
      isTrue,
    );
  });

  test('an unresolved claim above the floor survives past the bound and '
      'stays releasable and resolvable', () async {
    // Leave a claim in flight above where the floor will land, then drive
    // the pair well past the bound: pruning removes only rows the raised
    // floor passes over, so this one must survive.
    expect(
      await GroupSenderIndexStore.claimInboundIndex(
        groupId: groupId,
        senderId: senderId,
        index: seenRetained + 51,
      ),
      isTrue,
    );
    for (var i = 0; i <= seenRetained + 50; i++) {
      expect(
        await GroupSenderIndexStore.claimInboundIndex(
          groupId: groupId,
          senderId: senderId,
          index: i,
        ),
        isTrue,
      );
      await GroupSenderIndexStore.resolveInboundIndex(
        groupId: groupId,
        senderId: senderId,
        index: i,
      );
    }

    // The unresolved row above the floor was never pruned: pruning removes
    // only resolved rows and the rows the floor passes over.
    final unresolved = await db.query(
      'group_inbound_seen',
      where: 'groupId = ? AND senderId = ? AND msgIndex = ?',
      whereArgs: [groupId, senderId, seenRetained + 51],
    );
    expect(unresolved, hasLength(1));
    expect(unresolved.single['resolved'], 0);
    // The bound held for the resolved population (pruned 0..50, floor 51).
    expect(
      await db.query(
        'group_inbound_seen',
        where: 'groupId = ? AND senderId = ? AND resolved = 1',
        whereArgs: [groupId, senderId],
      ),
      hasLength(seenRetained),
    );
    final floor = await db.query('group_inbound_floor');
    expect(floor.single['prunedBelow'], 51);

    // Resolvable: the unresolved row resolves like any other. The prune
    // that runs inside the resolve keeps the bound by removing the pair's
    // oldest resolved row (51) and raising the floor to 52; the resolved
    // 307 sits inside the retained window and stays.
    await GroupSenderIndexStore.resolveInboundIndex(
      groupId: groupId,
      senderId: senderId,
      index: seenRetained + 51,
    );
    final afterResolve = await db.query(
      'group_inbound_seen',
      where: 'groupId = ? AND senderId = ? AND msgIndex = ?',
      whereArgs: [groupId, senderId, seenRetained + 51],
    );
    expect(afterResolve, hasLength(1));
    expect(afterResolve.single['resolved'], 1);
    expect(
      await db.query(
        'group_inbound_seen',
        where: 'groupId = ? AND senderId = ? AND resolved = 1',
        whereArgs: [groupId, senderId],
      ),
      hasLength(seenRetained),
    );
    expect(
      (await db.query('group_inbound_floor')).single['prunedBelow'],
      52,
    );

    // Releasable: a fresh unresolved claim past the bound releases and is
    // claimable again.
    expect(
      await GroupSenderIndexStore.claimInboundIndex(
        groupId: groupId,
        senderId: senderId,
        index: seenRetained + 52,
      ),
      isTrue,
    );
    await GroupSenderIndexStore.releaseInboundIndex(
      groupId: groupId,
      senderId: senderId,
      index: seenRetained + 52,
    );
    expect(
      await GroupSenderIndexStore.claimInboundIndex(
        groupId: groupId,
        senderId: senderId,
        index: seenRetained + 52,
      ),
      isTrue,
    );
  });

  test('an unresolved row the floor passes over is pruned: a crashed '
      'claim cannot leak below the retention bound', () async {
    // Leave index 0 claimed but unresolved — exactly the row a process
    // killed between claim and resolve leaves behind — then drive the pair
    // well past the bound.
    expect(
      await GroupSenderIndexStore.claimInboundIndex(
        groupId: groupId,
        senderId: senderId,
        index: 0,
      ),
      isTrue,
    );
    for (var i = 1; i <= seenRetained + 50; i++) {
      expect(
        await GroupSenderIndexStore.claimInboundIndex(
          groupId: groupId,
          senderId: senderId,
          index: i,
        ),
        isTrue,
      );
      await GroupSenderIndexStore.resolveInboundIndex(
        groupId: groupId,
        senderId: senderId,
        index: i,
      );
    }

    // The orphan row is gone: the floor (51) refuses index 0 forever, so
    // the row carried no information and must not survive past the bound
    // (pre-fix: it leaked, unresolved, forever).
    final orphan = await db.query(
      'group_inbound_seen',
      where: 'groupId = ? AND senderId = ? AND msgIndex = ?',
      whereArgs: [groupId, senderId, 0],
    );
    expect(orphan, isEmpty);
    // The row count stays within the documented bound: exactly the 256
    // retained resolved rows, no orphan above it.
    expect(await db.query('group_inbound_seen'), hasLength(seenRetained));
    final floor = await db.query('group_inbound_floor');
    expect(floor.single['prunedBelow'], 51);

    // The pruned index stays refused — by the floor now, not by the row.
    expect(
      await GroupSenderIndexStore.claimInboundIndex(
        groupId: groupId,
        senderId: senderId,
        index: 0,
      ),
      isFalse,
    );
  });

  test('pruning is scoped per (groupId, senderId): another sender\u0027s rows '
      'and floor are untouched', () async {
    const otherSender = 'peer.onion';
    // The other sender's index 0 is its own fresh sighting.
    expect(
      await GroupSenderIndexStore.claimInboundIndex(
        groupId: groupId,
        senderId: otherSender,
        index: 0,
      ),
      isTrue,
    );
    await GroupSenderIndexStore.resolveInboundIndex(
      groupId: groupId,
      senderId: otherSender,
      index: 0,
    );

    // Drive the pair under test past the bound (prunes 0..49, floor 50).
    for (var i = 0; i < seenRetained + 50; i++) {
      expect(
        await GroupSenderIndexStore.claimInboundIndex(
          groupId: groupId,
          senderId: senderId,
          index: i,
        ),
        isTrue,
      );
      await GroupSenderIndexStore.resolveInboundIndex(
        groupId: groupId,
        senderId: senderId,
        index: i,
      );
    }

    // The other sender kept exactly its one row; no floor row exists for
    // it, so its pruned-in-g1 indices are still fresh sightings.
    final otherRows = await db.query(
      'group_inbound_seen',
      where: 'groupId = ? AND senderId = ?',
      whereArgs: [groupId, otherSender],
    );
    expect(otherRows, hasLength(1));
    expect(otherRows.single['resolved'], 1);
    final floors = await db.query('group_inbound_floor');
    expect(floors, hasLength(1));
    expect(floors.single['senderId'], senderId);
    expect(floors.single['prunedBelow'], 50);
    expect(
      await GroupSenderIndexStore.claimInboundIndex(
        groupId: groupId,
        senderId: otherSender,
        index: 7,
      ),
      isTrue,
    );
  });

  test('resetForGroup clears rows and floor, and the same index is claimable '
      'again afterwards', () async {
    for (var i = 0; i < seenRetained + 50; i++) {
      expect(
        await GroupSenderIndexStore.claimInboundIndex(
          groupId: groupId,
          senderId: senderId,
          index: i,
        ),
        isTrue,
      );
      await GroupSenderIndexStore.resolveInboundIndex(
        groupId: groupId,
        senderId: senderId,
        index: i,
      );
    }
    expect(await db.query('group_inbound_seen'), isNotEmpty);
    expect(await db.query('group_inbound_floor'), hasLength(1));

    await GroupSenderIndexStore.resetForGroup(groupId);

    expect(await db.query('group_inbound_seen'), isEmpty);
    expect(await db.query('group_inbound_floor'), isEmpty);
    // A pruned index is claimable again after the reset.
    expect(
      await GroupSenderIndexStore.claimInboundIndex(
        groupId: groupId,
        senderId: senderId,
        index: 0,
      ),
      isTrue,
    );
  });
}
