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

    await dao.remove('m1');
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
}
