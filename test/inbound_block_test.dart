import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/database/blocked_users_db.dart';
import 'package:prysm/server/inbound_message_router.dart';
import 'package:prysm/services/block_service.dart';
import 'package:prysm/services/settings_service.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late InboundMessageRouter router;

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
    await BlockService.instance.block('blocked.onion');

    router = InboundMessageRouter(
      keyManager: KeyManager(),
      settings: SettingsService(),
      localOnionAddress: () => 'local.onion',
    );
  });

  tearDown(() {
    DBHelper.setDatabaseForTest(null);
  });

  test('processMessage acks but drops DM from blocked sender', () async {
    final result = await router.processMessage({
      'id': 'msg-1',
      'senderId': 'blocked.onion',
      'receiverId': 'local.onion',
      'message': 'cipher',
      'type': 'text',
      'timestamp': 1,
    });

    expect(result.statusCode, 200);
    expect(result.jsonBody?['status'], 'received');
    expect(result.jsonBody?['id'], 'msg-1');
  });

  test('buildProfile redacts info for blocked requester', () async {
    final result = await router.buildProfile(requesterOnion: 'blocked.onion');

    expect(result.statusCode, 200);
    expect(result.jsonBody?['username'], '');
    expect(result.jsonBody?['avatar'], '');
    expect(result.jsonBody?['identityJson'], '');
    expect(result.jsonBody?['publicKeyPem'], '');
  });

  test('buildProfile returns data for non-blocked requester', () async {
    final result = await router.buildProfile(requesterOnion: 'friend.onion');

    expect(result.statusCode, 200);
    expect(result.jsonBody?.containsKey('username'), isTrue);
  });

  test('buildProfile redacts when HTTP requester is required but missing', () async {
    final result = await router.buildProfile(requireRequester: true);

    expect(result.statusCode, 200);
    expect(result.jsonBody?['username'], '');
    expect(result.jsonBody?['avatar'], '');
  });

  test('handleSyncHint rejects blocked sender', () async {
    final result = await router.handleSyncHint({
      'senderId': 'blocked.onion',
      'receiverId': 'local.onion',
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });

    expect(result.statusCode, 403);
  });
}
