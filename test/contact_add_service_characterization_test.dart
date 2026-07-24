// Tests for ContactAddService (Fase 3.3).
//
// The `addContact` group characterizes the deterministic gate/fallback
// behavior (peer blocked, empty peer id, Tor stopped) against the
// ContactAddService.instance singleton, which always goes through
// TransportProvider's real fetch helpers -- these must survive the ctor
// injection refactor unchanged.
//
// The `fetch injection (Fase 3.3)` group exercises the identity/profile
// fetch functions injected via ContactAddService.forTesting: gate ordering,
// success/parsing/fingerprint-mismatch, and background enrichment
// (success + silent failure), none of which were deterministically
// testable before the transport became ctor-injectable.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/crypto/identity.dart';
import 'package:prysm/services/block_service.dart';
import 'package:prysm/services/contact_add_service.dart';
import 'package:prysm/transport/transport_provider.dart';
import 'package:prysm/util/conversation_refresh_notifier.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/util/tor_lifecycle_state.dart';
import 'package:prysm/util/tor_runtime_gate.dart';
import 'package:prysm/util/tor_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<Database> _openTestDb() async {
  final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
  await db.execute('''
    CREATE TABLE users (
      id TEXT PRIMARY KEY,
      name TEXT,
      avatarUrl TEXT,
      avatarBase64 TEXT,
      customName TEXT,
      publicKeyPem TEXT,
      identityJson TEXT
    )
  ''');
  await db.execute('''
    CREATE TABLE blocked_users (
      userId TEXT PRIMARY KEY,
      blockedAt INTEGER NOT NULL
    )
  ''');
  return db;
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  const onionId = 'peer.onion';

  late Database db;

  setUp(() async {
    db = await _openTestDb();
    DBHelper.setDatabaseForTest(db);
  });

  tearDown(() async {
    await BlockService.instance.unblock(onionId);
    await db.close();
    DBHelper.setDatabaseForTest(null);
    TransportProvider.resetForTest();
    TorRuntimeGate.resetForTest();
  });

  group('addContact', () {
    test(
        'returns false and does not insert a contact when the peer is '
        'blocked', () async {
      await BlockService.instance.block(onionId);

      final added = await ContactAddService.instance.addContact(
        onionId: onionId,
        displayName: 'Alice',
      );

      expect(added, isFalse);
      expect(await DBHelper.getUserById(onionId), isNull);
    });

    test(
        'returns false and does not insert a contact when the identity '
        'fetch yields nothing (empty peer id short-circuits the transport)',
        () async {
      final added = await ContactAddService.instance.addContact(
        onionId: '',
        displayName: 'Alice',
      );

      expect(added, isFalse);
      expect(await DBHelper.getUserById(''), isNull);
    });

    test(
        'returns false and does not insert a contact when the identity '
        'fetch fails (Tor stopped)', () async {
      TransportProvider.configure(
        TorManager(
          torPath: '/bin/false',
          dataDir: Directory.systemTemp.path,
        ),
      );
      TorRuntimeGate.resetForTest(lifecycle: TorLifecycleState.stopped);

      final added = await ContactAddService.instance.addContact(
        onionId: onionId,
        displayName: 'Alice',
      );

      expect(added, isFalse);
      expect(await DBHelper.getUserById(onionId), isNull);
    });
  });

  group('fetch injection (Fase 3.3)', () {
    late IdentityKeyPair peerKeyPair;
    late Map<String, dynamic> peerPublicJson;
    late String peerIdentityJson;

    setUp(() async {
      peerKeyPair = await IdentityKeyPair.generate();
      peerPublicJson = await peerKeyPair.toPublicJson();
      peerIdentityJson = jsonEncode(peerPublicJson);
    });

    test('does not call fetchPublic when the peer is blocked', () async {
      await BlockService.instance.block(onionId);
      final fetchPublicCalls = <String>[];

      final service = ContactAddService.forTesting(
        fetchPublic: (id) async {
          fetchPublicCalls.add(id);
          return peerIdentityJson;
        },
      );

      final added = await service.addContact(
        onionId: onionId,
        displayName: 'Alice',
      );

      expect(added, isFalse);
      expect(fetchPublicCalls, isEmpty);
    });

    test(
        'calls the injected fetchPublic with the onion id and inserts the '
        'contact on success', () async {
      final fetchPublicCalls = <String>[];

      final service = ContactAddService.forTesting(
        fetchPublic: (id) async {
          fetchPublicCalls.add(id);
          return peerIdentityJson;
        },
        fetchProfile: (_) async => '{}',
      );

      final added = await service.addContact(
        onionId: onionId,
        displayName: 'Alice',
      );

      expect(added, isTrue);
      expect(fetchPublicCalls, [onionId]);

      final row = await DBHelper.getUserById(onionId);
      expect(row, isNotNull);
      expect(row!['id'], onionId);
      expect(row['name'], 'Alice');
      expect(row['avatarUrl'], '');
      expect(row['avatarBase64'], isNull);
      expect(row['identityJson'], peerIdentityJson);
      expect(row['publicKeyPem'], peerIdentityJson);
    });

    test('returns false when the fetched identity JSON is malformed',
        () async {
      final service = ContactAddService.forTesting(
        fetchPublic: (_) async => 'not json',
      );

      final added = await service.addContact(
        onionId: onionId,
        displayName: 'Alice',
      );

      expect(added, isFalse);
      expect(await DBHelper.getUserById(onionId), isNull);
    });

    test(
        'returns false when the fetched identity fingerprint does not '
        'match expectedFingerprint', () async {
      final service = ContactAddService.forTesting(
        fetchPublic: (_) async => peerIdentityJson,
      );

      final added = await service.addContact(
        onionId: onionId,
        displayName: 'Alice',
        expectedFingerprint: 'not-the-real-fingerprint',
      );

      expect(added, isFalse);
      expect(await DBHelper.getUserById(onionId), isNull);
    });

    test(
        'background profile enrichment calls fetchProfile and updates '
        'name/avatar, notifying refresh listeners', () async {
      final fetchProfileCalls = <String>[];
      var refreshCount = 0;
      final sub =
          ConversationRefreshNotifier.instance.onRefresh.listen((_) {
        refreshCount++;
      });
      addTearDown(sub.cancel);

      final service = ContactAddService.forTesting(
        fetchPublic: (_) async => peerIdentityJson,
        fetchProfile: (id) async {
          fetchProfileCalls.add(id);
          return jsonEncode({
            'identityJson': peerIdentityJson,
            'username': 'Alice B.',
            'avatar': 'YWJj',
          });
        },
      );

      final added = await service.addContact(
        onionId: onionId,
        displayName: 'Alice',
      );
      expect(added, isTrue);

      Map<String, dynamic>? row;
      for (var i = 0; i < 20; i++) {
        row = await DBHelper.getUserById(onionId);
        if (row != null && row['avatarBase64'] == 'YWJj') break;
        await Future.delayed(const Duration(milliseconds: 5));
      }

      expect(fetchProfileCalls, [onionId]);
      expect(row?['name'], 'Alice B.');
      expect(row?['avatarBase64'], 'YWJj');
      expect(refreshCount, greaterThan(0));
    });

    test(
        'background profile enrichment failure does not throw or affect '
        'the already-added contact', () async {
      final service = ContactAddService.forTesting(
        fetchPublic: (_) async => peerIdentityJson,
        fetchProfile: (_) async => throw StateError('profile unreachable'),
      );

      final added = await service.addContact(
        onionId: onionId,
        displayName: 'Alice',
      );
      expect(added, isTrue);

      // Give the unawaited enrichment a chance to run (and fail silently).
      await Future.delayed(const Duration(milliseconds: 20));

      final row = await DBHelper.getUserById(onionId);
      expect(row!['name'], 'Alice');
      expect(row['avatarBase64'], isNull);
    });
  });
}
