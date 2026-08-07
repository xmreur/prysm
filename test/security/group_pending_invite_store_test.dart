// The pending-invite table is written by UNAUTHENTICATED inbound traffic:
// POST /message authenticates nobody and its only rate limit is keyed on the
// sender-claimed senderId (PrysmServer.dart:223-228). These tests pin the
// three bounds that keep it from being a remote write primitive.
import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/util/group_pending_invite_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<Database> _openDb() async {
  final db = await databaseFactory.openDatabase(
    '${inMemoryDatabasePath}_${DateTime.now().microsecondsSinceEpoch}',
    options: OpenDatabaseOptions(version: 1),
  );
  await GroupPendingInviteStore.ensureTable(db);
  return db;
}

void main() {
  late Database db;

  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    db = await _openDb();
    DBHelper.setDatabaseForTest(db);
  });

  tearDown(() async {
    await db.close();
    DBHelper.setDatabaseForTest(null);
  });

  test('a held invite comes back, newest first', () async {
    expect(await GroupPendingInviteStore.hold(
      senderId: 'a.onion',
      wire: 'wire-a',
    ), isTrue);
    expect(await GroupPendingInviteStore.hold(
      senderId: 'b.onion',
      wire: 'wire-b',
    ), isTrue);

    final rows = await GroupPendingInviteStore.pending();
    expect(rows, hasLength(2));
    expect(rows.first['senderId'], 'b.onion');
    expect(rows.first['wire'], 'wire-b');
    expect(await GroupPendingInviteStore.count(), 2);
  });

  test('a second invite from the same sender replaces the first', () async {
    await GroupPendingInviteStore.hold(senderId: 'a.onion', wire: 'first');
    await GroupPendingInviteStore.hold(senderId: 'a.onion', wire: 'second');

    final rows = await GroupPendingInviteStore.pending();
    expect(rows, hasLength(1));
    expect(rows.single['wire'], 'second');
  });

  test('the 21st distinct sender is refused and changes nothing', () async {
    for (var i = 0; i < GroupPendingInviteStore.maxPendingSenders; i++) {
      expect(
        await GroupPendingInviteStore.hold(senderId: 's$i.onion', wire: 'w$i'),
        isTrue,
      );
    }

    expect(
      await GroupPendingInviteStore.hold(
        senderId: 'one-too-many.onion',
        wire: 'w',
      ),
      isFalse,
    );
    expect(await GroupPendingInviteStore.count(),
        GroupPendingInviteStore.maxPendingSenders);
    // An existing sender may still refresh its own slot at capacity.
    expect(
      await GroupPendingInviteStore.hold(senderId: 's0.onion', wire: 'fresh'),
      isTrue,
    );
  });

  test('a row past the retention window is pruned, a fresh one is kept',
      () async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final expired = now - GroupPendingInviteStore.retention.inMilliseconds - 1;
    final fresh = now - GroupPendingInviteStore.retention.inMilliseconds ~/ 2;
    await db.insert('group_pending_invites', {
      'senderId': 'old.onion',
      'wire': 'old',
      'receivedAt': expired,
    });
    await db.insert('group_pending_invites', {
      'senderId': 'recent.onion',
      'wire': 'recent',
      'receivedAt': fresh,
    });

    expect(await GroupPendingInviteStore.count(), 1);
    final rows = await GroupPendingInviteStore.pending();
    expect(rows.single['senderId'], 'recent.onion');
  });

  test('a wire longer than the bound is refused and changes nothing',
      () async {
    expect(
      await GroupPendingInviteStore.hold(
        senderId: 'big.onion',
        wire: 'x' * (GroupPendingInviteStore.maxPendingWireChars + 1),
      ),
      isFalse,
    );
    expect(await GroupPendingInviteStore.count(), 0);

    // A wire exactly at the bound is accepted.
    expect(
      await GroupPendingInviteStore.hold(
        senderId: 'at-bound.onion',
        wire: 'x' * GroupPendingInviteStore.maxPendingWireChars,
      ),
      isTrue,
    );
    expect(await GroupPendingInviteStore.count(), 1);
  });

  test('take returns the wire once and deletes the row', () async {
    await GroupPendingInviteStore.hold(senderId: 'a.onion', wire: 'wire-a');

    expect(await GroupPendingInviteStore.take('a.onion'), 'wire-a');
    expect(await GroupPendingInviteStore.take('a.onion'), isNull);
    expect(await GroupPendingInviteStore.count(), 0);
  });

  test('discard removes the row without returning it', () async {
    await GroupPendingInviteStore.hold(senderId: 'a.onion', wire: 'wire-a');

    await GroupPendingInviteStore.discard('a.onion');
    expect(await GroupPendingInviteStore.count(), 0);
  });
}
