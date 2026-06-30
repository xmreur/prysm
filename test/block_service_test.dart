import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/database/blocked_users_db.dart';
import 'package:prysm/services/block_service.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    final db = await databaseFactory.openDatabase(
      '${inMemoryDatabasePath}_${DateTime.now().microsecondsSinceEpoch}',
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, _) async {
          await BlockedUsersDb.createTable(db);
        },
      ),
    );
    DBHelper.setDatabaseForTest(db);
    await BlockService.instance.init();
  });

  tearDown(() {
    DBHelper.setDatabaseForTest(null);
  });

  test('block and unblock update cache and database', () async {
    expect(BlockService.instance.isBlocked('peer.onion'), isFalse);

    await BlockService.instance.block('peer.onion');
    expect(BlockService.instance.isBlocked('peer.onion'), isTrue);
    expect(BlockService.instance.blockedIds, contains('peer.onion'));
    expect(BlockService.instance.blockedAt('peer.onion'), isNotNull);

    expect(await BlockedUsersDb.isBlocked('peer.onion'), isTrue);

    await BlockService.instance.unblock('peer.onion');
    expect(BlockService.instance.isBlocked('peer.onion'), isFalse);
    expect(await BlockedUsersDb.isBlocked('peer.onion'), isFalse);
  });

  test('init reloads blocked users from database', () async {
    await BlockedUsersDb.block('a.onion', 100);
    await BlockedUsersDb.block('b.onion', 200);

    await BlockService.instance.init();

    expect(BlockService.instance.blockedIds, containsAll(['a.onion', 'b.onion']));
    expect(BlockService.instance.blockedAt('b.onion'), 200);
  });
}
