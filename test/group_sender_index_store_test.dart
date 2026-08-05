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
}
