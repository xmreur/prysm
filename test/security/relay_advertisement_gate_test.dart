/// The relay advertisement is the one part of `/profile` whose construction
/// *writes*: it registers a mailbox at the relay, one per requester address.
/// Publishing it to anyone who asks is a resource-exhaustion channel.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/database/blocked_users_db.dart';
import 'package:prysm/server/inbound_message_router.dart';
import 'package:prysm/services/block_service.dart';
import 'package:prysm/services/settings_service.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _contact = 'x55eyojvaadl75tsz5s4ee7zu6ckq6cifrhzrlcuu7my72rxeqrz5ead.onion';
const _stranger =
    'k5cjn3lna3yaxx2hbgnofqln45dbythuj5d4ekzkf42jy3e6mkgst2yd.onion';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Database db;
  late List<String> advertisedTo;
  late InboundMessageRouter router;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    db = await databaseFactory.openDatabase(
      '${inMemoryDatabasePath}_${DateTime.now().microsecondsSinceEpoch}',
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, _) async {
          await db.execute('''
            CREATE TABLE users (
              id TEXT PRIMARY KEY,
              name TEXT,
              publicKeyPem TEXT,
              identityJson TEXT
            )
          ''');
          await BlockedUsersDb.createTable(db);
        },
      ),
    );
    DBHelper.setDatabaseForTest(db);
    await BlockService.instance.init();

    advertisedTo = [];
    router = InboundMessageRouter(
      keyManager: KeyManager(),
      settings: SettingsService(),
      localOnionAddress: () => 'local.onion',
      buildRelayAdvertisement: (requester) async {
        advertisedTo.add(requester);
        return {'v': 1, 'relays': const []};
      },
    );
  });

  tearDown(() async {
    DBHelper.setDatabaseForTest(null);
    await db.close();
  });

  Future<void> addContact(String id) =>
      db.insert('users', {'id': id, 'name': 'peer'});

  test('an unknown requester gets no advertisement and no mailbox', () async {
    final result = await router.buildProfile(requesterOnion: _stranger);

    expect(result.statusCode, 200);
    expect(result.jsonBody?.containsKey('relay'), isFalse);
    // The important half: nothing was registered at the relay for a stranger.
    expect(advertisedTo, isEmpty);
  });

  test('a known contact still gets its own advertisement', () async {
    await addContact(_contact);

    final result = await router.buildProfile(requesterOnion: _contact);

    expect(result.statusCode, 200);
    expect(result.jsonBody?['relay'], isNotNull);
    expect(advertisedTo, [_contact]);
  });

  test('a blocked contact gets neither profile nor advertisement', () async {
    await addContact(_contact);
    await BlockService.instance.block(_contact);

    final result = await router.buildProfile(requesterOnion: _contact);

    expect(result.jsonBody?['identityJson'], '');
    expect(result.jsonBody?.containsKey('relay'), isFalse);
    expect(advertisedTo, isEmpty);
  });

  test('a profile fetch with no requester never advertises', () async {
    final result = await router.buildProfile();

    expect(result.statusCode, 200);
    expect(result.jsonBody?.containsKey('relay'), isFalse);
    expect(advertisedTo, isEmpty);
  });
}
