import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('v17 create ships owner lock and mute columns', () async {
    final db = await databaseFactory.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    addTearDown(() async => db.close());
    await db.execute('''
      CREATE TABLE groups (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        avatarBase64 TEXT,
        createdBy TEXT NOT NULL,
        createdAt INTEGER NOT NULL,
        onlyAdminsCanAdd INTEGER NOT NULL DEFAULT 1
      )
    ''');
    await db.execute('''
      CREATE TABLE group_members (
        groupId TEXT NOT NULL,
        memberId TEXT NOT NULL,
        role TEXT NOT NULL,
        joinedAt INTEGER NOT NULL,
        muted INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (groupId, memberId)
      )
    ''');
    expect(
      (await db.rawQuery('PRAGMA table_info(groups)')).map((c) => c['name']),
      contains('onlyAdminsCanAdd'),
    );
    expect(
      (await db.rawQuery('PRAGMA table_info(group_members)'))
          .map((c) => c['name']),
      contains('muted'),
    );
  });

  test('applyGroupModerationV17 backfills creator admin to owner', () async {
    final db = await databaseFactory.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    addTearDown(() async => db.close());
    await db.execute('''
      CREATE TABLE groups (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        avatarBase64 TEXT,
        createdBy TEXT NOT NULL,
        createdAt INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE group_members (
        groupId TEXT NOT NULL,
        memberId TEXT NOT NULL,
        role TEXT NOT NULL,
        joinedAt INTEGER NOT NULL,
        PRIMARY KEY (groupId, memberId)
      )
    ''');
    await db.insert('groups', {
      'id': 'g1',
      'name': 'Squad',
      'createdBy': 'creator.onion',
      'createdAt': 1,
    });
    await db.insert('group_members', {
      'groupId': 'g1',
      'memberId': 'creator.onion',
      'role': 'admin',
      'joinedAt': 1,
    });
    await db.insert('group_members', {
      'groupId': 'g1',
      'memberId': 'admin.onion',
      'role': 'admin',
      'joinedAt': 1,
    });
    await db.insert('group_members', {
      'groupId': 'g1',
      'memberId': 'member.onion',
      'role': 'member',
      'joinedAt': 1,
    });

    await DBHelper.applyGroupModerationV17(db);

    final groupCols = await db.rawQuery('PRAGMA table_info(groups)');
    expect(groupCols.map((c) => c['name']), contains('onlyAdminsCanAdd'));
    final memberCols = await db.rawQuery('PRAGMA table_info(group_members)');
    expect(memberCols.map((c) => c['name']), contains('muted'));

    final members = {
      for (final row in await db.query('group_members'))
        row['memberId'] as String: row,
    };
    expect(members['creator.onion']!['role'], 'owner');
    expect(members['admin.onion']!['role'], 'admin');
    expect(members['member.onion']!['role'], 'member');
    expect(members['creator.onion']!['muted'], 0);
    expect((await db.query('groups')).single['onlyAdminsCanAdd'], 1);
  });
}
