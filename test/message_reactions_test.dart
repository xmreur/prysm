import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/database/message_reactions.dart';
import 'package:prysm/database/messages.dart';
import 'package:prysm/util/reaction_payload.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    MessageReactionsDb.debugDatabase = await databaseFactory.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        onCreate: (db, version) async {
          await MessageReactionsDb.createTable(db);
        },
        version: 1,
      ),
    );
  });

  tearDown(() async {
    await MessageReactionsDb.debugDatabase?.close();
    MessageReactionsDb.debugDatabase = null;
  });

  test('ReactionPayload round-trip', () {
    final payload = ReactionPayload(
      targetMessageId: 'msg-1',
      emoji: '👍',
      action: 'add',
      timestamp: 1710000000000,
    );
    final decoded = ReactionPayload.decode(payload.encode());
    expect(decoded.targetMessageId, 'msg-1');
    expect(decoded.emoji, '👍');
    expect(decoded.isAdd, isTrue);
  });

  test('aggregateReactions groups by emoji', () {
    final map = aggregateReactions([
      {'emoji': '👍', 'reactorId': 'a'},
      {'emoji': '👍', 'reactorId': 'b'},
      {'emoji': '❤️', 'reactorId': 'c'},
    ]);
    expect(map['👍'], ['a', 'b']);
    expect(map['❤️'], ['c']);
  });

  test('upsert replaces emoji for same target and reactor', () async {
    const target = 'msg-abc';
    const reactor = 'user.onion';

    await MessageReactionsDb.upsertReaction(
      targetMessageId: target,
      reactorId: reactor,
      emoji: '👍',
      timestamp: 100,
    );
    await MessageReactionsDb.upsertReaction(
      targetMessageId: target,
      reactorId: reactor,
      emoji: '❤️',
      timestamp: 101,
    );

    final map = await MessageReactionsDb.getReactionsForMessages([target]);
    expect(map[target], {'❤️': [reactor]});
  });

  test('removeReaction deletes row', () async {
    const target = 'msg-del';
    await MessageReactionsDb.upsertReaction(
      targetMessageId: target,
      reactorId: 'u1',
      emoji: '😂',
      timestamp: 1,
    );
    await MessageReactionsDb.removeReaction(
      targetMessageId: target,
      reactorId: 'u1',
    );
    final map = await MessageReactionsDb.getReactionsForMessages([target]);
    expect(map.containsKey(target), isFalse);
  });

  test('group reactions use scoped storage ids', () async {
    const groupId = 'group-1';
    const wireId = 'wire-1';
    final storageId = MessagesDb.scopedId(wireId: wireId, groupId: groupId);

    await MessageReactionsDb.upsertReaction(
      targetMessageId: storageId,
      reactorId: 'peer.onion',
      emoji: '🙏',
      groupId: groupId,
      timestamp: 50,
    );

    final map = await MessageReactionsDb.getReactionsForMessages(
      [wireId],
      groupId: groupId,
    );
    expect(map[wireId], {'🙏': ['peer.onion']});
  });

  test('deleteReactionsForMessage clears all reactions', () async {
    const target = 'msg-all';
    await MessageReactionsDb.upsertReaction(
      targetMessageId: target,
      reactorId: 'a',
      emoji: '👍',
      timestamp: 1,
    );
    await MessageReactionsDb.upsertReaction(
      targetMessageId: target,
      reactorId: 'b',
      emoji: '👍',
      timestamp: 2,
    );
    await MessageReactionsDb.deleteReactionsForMessage(target);
    final map = await MessageReactionsDb.getReactionsForMessages([target]);
    expect(map.isEmpty, isTrue);
  });
}
