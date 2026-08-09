import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/database/message_schema_migrations.dart';
import 'package:prysm/database/message_search_dao.dart';
import 'package:prysm/database/messages.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
    await MessageSchemaMigrations.onCreate(db, MessageSchemaMigrations.dbVersion);
    MessagesDb.setDatabaseForTest(db);
  });

  tearDown(() async {
    await MessagesDb.close();
    MessagesDb.setDatabaseForTest(null);
  });

  test('escapeFtsQuery builds prefix OR query', () {
    expect(
      MessageSearchDao.escapeFtsQuery('hello world'),
      '"hello"* OR "world"*',
    );
    expect(MessageSearchDao.escapeFtsQuery('  '), '');
  });

  test('upsert search remove and global search', () async {
    const dao = MessageSearchDao();
    await dao.upsert(
      messageId: 'm1',
      conversationId: 'peer1',
      scope: 'direct',
      timestamp: 100,
      body: 'hello world',
    );
    await dao.upsert(
      messageId: 'm2',
      conversationId: 'peer2',
      scope: 'direct',
      timestamp: 200,
      body: 'goodbye moon',
    );

    final hits = await dao.searchGlobal('hello');
    expect(hits, hasLength(1));
    expect(hits.first.messageId, 'm1');

    final scoped = await dao.searchInConversation('peer2', 'moon');
    expect(scoped, hasLength(1));
    expect(scoped.first.messageId, 'm2');

    await dao.remove('m1', conversationId: 'peer1', scope: 'direct');
    expect(
      await dao.exists(
        messageId: 'm1',
        conversationId: 'peer1',
        scope: 'direct',
      ),
      isFalse,
    );
    expect(await dao.searchGlobal('hello'), isEmpty);
  });

  test('upsert replaces existing row for same messageId', () async {
    const dao = MessageSearchDao();
    await dao.upsert(
      messageId: 'm1',
      conversationId: 'peer1',
      scope: 'direct',
      timestamp: 100,
      body: 'first text',
    );
    await dao.upsert(
      messageId: 'm1',
      conversationId: 'peer1',
      scope: 'direct',
      timestamp: 100,
      body: 'edited text',
    );

    final hits = await dao.searchGlobal('edited');
    expect(hits, hasLength(1));
    expect(hits.first.body, 'edited text');
  });

  test('upsert with empty trimmed body removes the existing index row',
      () async {
    const dao = MessageSearchDao();
    await dao.upsert(
      messageId: 'm1',
      conversationId: 'peer1',
      scope: 'direct',
      timestamp: 100,
      body: 'hello world',
    );
    expect(await dao.searchGlobal('hello'), hasLength(1));

    await dao.upsert(
      messageId: 'm1',
      conversationId: 'peer1',
      scope: 'direct',
      timestamp: 100,
      body: '   ',
    );

    expect(await dao.searchGlobal('hello'), isEmpty);
    expect(
      await dao.exists(
        messageId: 'm1',
        conversationId: 'peer1',
        scope: 'direct',
      ),
      isFalse,
    );
  });

  test('same messageId in two groups stays independent', () async {
    const dao = MessageSearchDao();
    await dao.upsert(
      messageId: 'shared',
      conversationId: 'groupA',
      scope: 'group',
      timestamp: 100,
      body: 'hello alpha',
    );
    await dao.upsert(
      messageId: 'shared',
      conversationId: 'groupB',
      scope: 'group',
      timestamp: 200,
      body: 'hello beta',
    );

    // Upserting one group must not replace or delete the other group's hit.
    await dao.upsert(
      messageId: 'shared',
      conversationId: 'groupA',
      scope: 'group',
      timestamp: 100,
      body: 'edited alpha',
    );

    final editedHits = await dao.searchGlobal('edited');
    expect(editedHits, hasLength(1));
    expect(editedHits.first.conversationId, 'groupA');
    final betaHits = await dao.searchGlobal('beta');
    expect(betaHits, hasLength(1));
    expect(betaHits.first.conversationId, 'groupB');

    // Removing one group must not delete the other group's hit.
    await dao.remove('shared', conversationId: 'groupA', scope: 'group');
    expect(
      await dao.exists(
        messageId: 'shared',
        conversationId: 'groupA',
        scope: 'group',
      ),
      isFalse,
    );
    expect(
      await dao.exists(
        messageId: 'shared',
        conversationId: 'groupB',
        scope: 'group',
      ),
      isTrue,
    );
    final remaining = await dao.searchGlobal('beta');
    expect(remaining, hasLength(1));
    expect(remaining.first.conversationId, 'groupB');

    await dao.remove('shared', conversationId: 'groupB', scope: 'group');
    expect(
      await dao.exists(
        messageId: 'shared',
        conversationId: 'groupB',
        scope: 'group',
      ),
      isFalse,
    );
  });

  test('delete paths remove the row from both the FTS and rowid side tables',
      () async {
    const dao = MessageSearchDao();
    final db = await MessagesDb.database;

    Future<int> sideRowsFor(String messageId) async =>
        (await db.query(
          'message_search_rows',
          where: 'messageId = ?',
          whereArgs: [messageId],
        ))
            .length;

    await dao.upsert(
      messageId: 'a',
      conversationId: 'peer',
      scope: 'direct',
      timestamp: 1,
      body: 'alpha needle',
    );
    await dao.upsert(
      messageId: 'b',
      conversationId: 'peer',
      scope: 'direct',
      timestamp: 2,
      body: 'beta needle',
    );
    await dao.upsert(
      messageId: 'c',
      conversationId: 'peer',
      scope: 'direct',
      timestamp: 3,
      body: 'gamma needle',
    );
    await dao.upsert(
      messageId: 'd',
      conversationId: 'g1',
      scope: 'group',
      timestamp: 4,
      body: 'delta needle',
    );
    await dao.upsert(
      messageId: 'e',
      conversationId: 'g1',
      scope: 'group',
      timestamp: 5,
      body: 'echo needle',
    );
    await dao.upsert(
      messageId: 'f',
      conversationId: 'g1',
      scope: 'group',
      timestamp: 6,
      body: 'foxtrot needle',
    );
    // Every upsert writes both tables.
    expect(await sideRowsFor('a'), 1);
    expect(await sideRowsFor('e'), 1);

    // Single-row remove.
    await dao.remove('a', conversationId: 'peer', scope: 'direct');
    expect(await dao.searchGlobal('alpha'), isEmpty);
    expect(await sideRowsFor('a'), 0);

    // Upsert with an empty trimmed body is a delete-only path.
    await dao.upsert(
      messageId: 'b',
      conversationId: 'peer',
      scope: 'direct',
      timestamp: 2,
      body: '   ',
    );
    expect(await dao.searchGlobal('beta'), isEmpty);
    expect(await sideRowsFor('b'), 0);

    // Conversation-wide delete.
    await dao.removeForConversationUnprotected('peer', 'direct');
    expect(await dao.searchGlobal('gamma'), isEmpty);
    expect(await sideRowsFor('c'), 0);

    // Conversation-wide delete with a beforeTimestamp keeps newer rows in
    // both tables.
    await dao.removeForConversationUnprotected('g1', 'group',
        beforeTimestamp: 5);
    expect(await dao.searchGlobal('delta'), isEmpty);
    expect(await sideRowsFor('d'), 0);
    final kept = await dao.searchGlobal('echo');
    expect(kept, hasLength(1));
    expect(await sideRowsFor('e'), 1);
    expect(await dao.searchGlobal('foxtrot'), hasLength(1));
    expect(await sideRowsFor('f'), 1);
  });

  test('upsert/remove cost stays flat as the index grows (rowid side table)',
      () async {
    const dao = MessageSearchDao();
    final db = await MessagesDb.database;

    // Seed the FTS table directly (O(N), fast) and backfill the side table
    // the same way the v15 migration does, so a seeded row exists in both
    // tables. On the pre-fix schema the side table does not exist and the
    // backfill is a no-op — every remove then full-scans the index.
    Future<void> syncSideTable() async {
      final hasSideTable = (await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' "
        "AND name='message_search_rows'",
      )).isNotEmpty;
      if (!hasSideTable) return;
      await db.rawInsert('''
        INSERT OR IGNORE INTO message_search_rows(
          messageId, conversationId, scope, timestamp, ftsRowid
        )
        SELECT messageId, conversationId, scope, timestamp, rowid
        FROM message_search_fts
      ''');
    }

    Future<void> seed(int count, int start) async {
      final batch = db.batch();
      for (var i = start; i < start + count; i++) {
        batch.insert('message_search_fts', {
          'messageId': 'seed-$i',
          'conversationId': 'peer',
          'scope': 'direct',
          'timestamp': i,
          'body': 'seeded body number $i',
        });
      }
      await batch.commit(noResult: true);
      await syncSideTable();
    }

    // Removes existing rows in three rounds and returns the median per-op
    // duration, so one slow round cannot skew the comparison.
    Future<double> medianRemoveMicros(int firstRow) async {
      final samples = <double>[];
      var row = firstRow;
      for (var round = 0; round < 3; round++) {
        final sw = Stopwatch()..start();
        for (var i = 0; i < 15; i++) {
          await dao.remove('seed-$row',
              conversationId: 'peer', scope: 'direct');
          row++;
        }
        sw.stop();
        samples.add(sw.elapsedMicroseconds / 15);
      }
      samples.sort();
      return samples[samples.length ~/ 2];
    }

    await seed(2000, 0);
    final smallPerOp = await medianRemoveMicros(0);

    await seed(18000, 2000);
    final largePerOp = await medianRemoveMicros(2000);

    // The rowid probe keeps the ratio near 1 (~0.9x measured on this
    // machine); an O(N) scan of the UNINDEXED FTS metadata columns measures
    // 3.2-3.8x at 20k rows — the scan alone scales ~10x, but ~0.55ms of
    // fixed per-op mutex/transaction/FFI overhead dilutes the total. Bound
    // at 3x to sit between the two. Floor the denominator at 20us so a
    // small-index measurement that collapses to a few us (fast runner)
    // cannot let one scheduler stall push the ratio through the bound;
    // inert on this machine, where smallPerOp never drops below ~0.6ms.
    const floorMicros = 20.0;
    final smallDenominator =
        smallPerOp < floorMicros ? floorMicros : smallPerOp;
    expect(
      largePerOp,
      lessThan(smallDenominator * 3),
      reason: 'per-op delete grew '
          '${(largePerOp / smallDenominator).toStringAsFixed(1)}x '
          '(${smallDenominator.toStringAsFixed(1)}us -> '
          '${largePerOp.toStringAsFixed(1)}us) between ~2k and ~20k rows',
    );
  });

  test('a mid-sequence failure cannot leave a stale side row behind (remove)',
      () async {
    const dao = MessageSearchDao();
    final db = await MessagesDb.database;
    await dao.upsert(
      messageId: 'm1',
      conversationId: 'peer',
      scope: 'direct',
      timestamp: 1,
      body: 'alpha needle',
    );

    // Simulate a crash between the two writes that remove() used to make as
    // separate autocommitted statements: the second write (the side-row
    // delete) aborts. The committed state must stay consistent — either both
    // rows survive or neither does — never a stale side row pointing at a
    // freed FTS rowid.
    await db.execute('''
      CREATE TRIGGER fail_side_delete
      BEFORE DELETE ON message_search_rows
      BEGIN
        SELECT RAISE(ABORT, 'injected mid-sequence failure');
      END
    ''');
    await expectLater(
      dao.remove('m1', conversationId: 'peer', scope: 'direct'),
      throwsA(isA<DatabaseException>()),
    );

    final sideRows = await db.query(
      'message_search_rows',
      where: 'messageId = ?',
      whereArgs: ['m1'],
    );
    final ftsRows = await db.query(
      'message_search_fts',
      where: 'messageId = ?',
      whereArgs: ['m1'],
    );
    expect(
      sideRows,
      hasLength(ftsRows.length),
      reason: 'side row and FTS row diverged after a mid-sequence failure: '
          '${sideRows.length} side row(s) vs ${ftsRows.length} FTS row(s)',
    );
    expect(sideRows, hasLength(1), reason: 'the delete was rolled back whole');
    expect(await dao.searchGlobal('alpha'), hasLength(1),
        reason: 'the message must stay searchable after the rollback');
  });

  test('a mid-sequence failure cannot leave an orphan FTS row behind (upsert)',
      () async {
    const dao = MessageSearchDao();
    final db = await MessagesDb.database;
    await db.execute('''
      CREATE TRIGGER fail_side_insert
      BEFORE INSERT ON message_search_rows
      BEGIN
        SELECT RAISE(ABORT, 'injected mid-sequence failure');
      END
    ''');
    await expectLater(
      dao.upsert(
        messageId: 'm1',
        conversationId: 'peer',
        scope: 'direct',
        timestamp: 1,
        body: 'alpha needle',
      ),
      throwsA(isA<DatabaseException>()),
    );

    final sideRows = await db.query(
      'message_search_rows',
      where: 'messageId = ?',
      whereArgs: ['m1'],
    );
    final ftsRows = await db.query(
      'message_search_fts',
      where: 'messageId = ?',
      whereArgs: ['m1'],
    );
    expect(
      sideRows,
      hasLength(ftsRows.length),
      reason: 'side row and FTS row diverged after a mid-sequence failure: '
          '${sideRows.length} side row(s) vs ${ftsRows.length} FTS row(s)',
    );
    expect(sideRows, isEmpty, reason: 'the upsert was rolled back whole');
    expect(await dao.searchGlobal('alpha'), isEmpty,
        reason: 'no orphan FTS row may stay searchable');
  });

  test('a stale side row pointing at a reused rowid cannot delete another '
      'message', () async {
    const dao = MessageSearchDao();
    final db = await MessagesDb.database;
    await dao.upsert(
      messageId: 'm1',
      conversationId: 'peer',
      scope: 'direct',
      timestamp: 1,
      body: 'alpha needle',
    );
    await dao.upsert(
      messageId: 'm2',
      conversationId: 'peer',
      scope: 'direct',
      timestamp: 2,
      body: 'beta needle',
    );
    final m1Rowid = (await db.query(
      'message_search_rows',
      columns: const ['ftsRowid'],
      where: 'messageId = ?',
      whereArgs: ['m1'],
    )).first['ftsRowid'] as int;
    final m2Rowid = (await db.query(
      'message_search_rows',
      columns: const ['ftsRowid'],
      where: 'messageId = ?',
      whereArgs: ['m2'],
    )).first['ftsRowid'] as int;

    // A crash between the two writes of a pre-transactional remove('m1')
    // leaves m1's side row pointing at a freed FTS rowid; FTS5 is free to
    // hand that rowid to a later message. Reproduce that state directly:
    // m1's FTS entry is gone, and its surviving side row now names m2's
    // rowid (the exact invariant violation the crash + reuse produces).
    await db.delete(
      'message_search_fts',
      where: 'rowid = ?',
      whereArgs: [m1Rowid],
    );
    await db.update(
      'message_search_rows',
      {'ftsRowid': m2Rowid},
      where: 'messageId = ?',
      whereArgs: ['m1'],
    );

    await dao.remove('m1', conversationId: 'peer', scope: 'direct');

    // m2's index entry must survive: the stale rowid now identifies m2, not
    // m1, and must not be deleted.
    final hits = await dao.searchGlobal('beta');
    expect(hits, hasLength(1));
    expect(hits.first.messageId, 'm2');
    expect(
      await dao.exists(
        messageId: 'm2',
        conversationId: 'peer',
        scope: 'direct',
      ),
      isTrue,
    );
    // m1 is fully gone from both tables.
    expect(
      await dao.exists(
        messageId: 'm1',
        conversationId: 'peer',
        scope: 'direct',
      ),
      isFalse,
    );
    expect(await dao.searchGlobal('alpha'), isEmpty);
  });
}
