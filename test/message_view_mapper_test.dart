// Unit tests for MessageViewMapper (Fase 6A): the row→Message decrypt/
// mapping pipeline extracted from _ChatScreenState/_GroupChatScreenState.
// See message_view_mapper_characterization_test.dart for the baseline this
// was extracted from — these tests exercise the real class directly.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/constants/media_constants.dart';
import 'package:prysm/crypto/group_crypto.dart';
import 'package:prysm/crypto/identity.dart';
import 'package:prysm/crypto/ratchet/session_store.dart';
import 'package:prysm/database/message_read_receipts.dart';
import 'package:prysm/database/messages.dart';
import 'package:prysm/models/chat/prysm_message.dart';
import 'package:prysm/services/message_view_mapper.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<Database> _openMessagesDb() async {
  final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
  await MessageReadReceiptsDb.createTable(db);
  return db;
}

Future<Database> _openDbHelperDb() async {
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
  await RatchetSessionStore.ensureTable(db);
  return db;
}

Future<Map<String, Map<String, List<String>>>> _noReactions(List<String> ids) async {
  return const {};
}

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database messagesDb;
  late Database dbHelperDb;
  late KeyManager keyManager;
  late MessageViewMapper mapper;

  setUp(() async {
    messagesDb = await _openMessagesDb();
    MessagesDb.setDatabaseForTest(messagesDb);

    dbHelperDb = await _openDbHelperDb();
    DBHelper.setDatabaseForTest(dbHelperDb);

    keyManager = KeyManager.fromIdentity(await IdentityKeyPair.generate());
    mapper = MessageViewMapper(keyManager: keyManager);
  });

  tearDown(() async {
    await messagesDb.close();
    MessagesDb.setDatabaseForTest(null);

    await dbHelperDb.close();
    DBHelper.setDatabaseForTest(null);
  });

  group('decryptDirectTextMessage', () {
    test('self-authored row decrypts via KeyManager.decryptMessage', () async {
      final wire = await keyManager.encryptForSelf('hi there');
      final text = await mapper.decryptDirectTextMessage(
        {'senderId': 'me', 'message': wire},
        localUserId: 'me',
      );
      expect(text, 'hi there');
    });

    test('empty payload throws FormatException', () {
      expect(
        () => mapper.decryptDirectTextMessage(
          {'senderId': 'me', 'message': ''},
          localUserId: 'me',
        ),
        throwsFormatException,
      );
    });

    test('unknown peer without an identity on file throws FormatException',
        () {
      expect(
        () => mapper.decryptDirectTextMessage(
          {'senderId': 'stranger', 'message': 'cipher'},
          localUserId: 'me',
        ),
        throwsFormatException,
      );
    });

    test('a misrouted group control payload is rejected before decrypting',
        () {
      final envelope = jsonEncode({'envelope': 'prysm-v2', 'iv': 'x', 'ct': 'y'});
      expect(
        () => mapper.decryptDirectTextMessage(
          {'senderId': 'me', 'message': envelope},
          localUserId: 'me',
        ),
        throwsFormatException,
      );
    });
  });

  group('mapDirectRows', () {
    test('decrypts a self-authored text row', () async {
      final wire = await keyManager.encryptForSelf('mapped text');
      final result = await mapper.mapDirectRows(
        [
          {
            'id': 'm1',
            'senderId': 'me',
            'receiverId': 'peer',
            'message': wire,
            'type': 'text',
            'timestamp': 1000,
            'status': 'sent',
          },
        ],
        localUserId: 'me',
        cache: {},
        loadReactionsForMessages: _noReactions,
        readReceiptsEnabled: false,
      );

      final msg = result.single as TextMessage;
      expect(msg.text, 'mapped text');
      expect(msg.id, 'm1');
    });

    test('reuses a cached message instead of decrypting', () async {
      final cached = TextMessage(id: 'm-cached', authorId: 'peer', text: 'cached');
      final result = await mapper.mapDirectRows(
        [
          {
            'id': 'm-cached',
            'senderId': 'peer',
            'receiverId': 'me',
            'message': 'would-fail-to-decrypt',
            'type': 'text',
            'timestamp': 1000,
          },
        ],
        localUserId: 'me',
        cache: {'m-cached': cached},
        loadReactionsForMessages: _noReactions,
        readReceiptsEnabled: false,
      );

      expect(result.single, same(cached));
    });

    test('an undecryptable row falls back to the lock-emoji placeholder',
        () async {
      final result = await mapper.mapDirectRows(
        [
          {
            'id': 'm-bad',
            'senderId': 'stranger',
            'receiverId': 'me',
            'message': 'cipher',
            'type': 'text',
            'timestamp': 1000,
          },
        ],
        localUserId: 'me',
        cache: {},
        loadReactionsForMessages: _noReactions,
        readReceiptsEnabled: false,
      );

      final msg = result.single as TextMessage;
      expect(msg.text, '🔒 Unable to decrypt message');
    });

    test('a deletedAt row maps to an empty-text deleted placeholder', () async {
      final result = await mapper.mapDirectRows(
        [
          {
            'id': 'm-deleted',
            'senderId': 'peer',
            'receiverId': 'me',
            'message': 'cipher',
            'type': 'text',
            'timestamp': 1000,
            'deletedAt': 2000,
          },
        ],
        localUserId: 'me',
        cache: {},
        loadReactionsForMessages: _noReactions,
        readReceiptsEnabled: false,
      );

      final msg = result.single as TextMessage;
      expect(msg.text, '');
      expect(msg.metadata, {'deleted': true});
    });

    test('a file row maps to a FileMessage', () async {
      final result = await mapper.mapDirectRows(
        [
          {
            'id': 'm-file',
            'senderId': 'peer',
            'receiverId': 'me',
            'message': 'wire-ref',
            'type': 'file',
            'fileName': 'report.pdf',
            'fileSize': 99,
            'timestamp': 1000,
          },
        ],
        localUserId: 'me',
        cache: {},
        loadReactionsForMessages: _noReactions,
        readReceiptsEnabled: false,
      );

      final msg = result.single as FileMessage;
      expect(msg.name, 'report.pdf');
      expect(msg.size, 99);
    });

    test('a non-viewOnce image row gets a deferred source', () async {
      final result = await mapper.mapDirectRows(
        [
          {
            'id': 'm-img',
            'senderId': 'peer',
            'receiverId': 'me',
            'message': 'cipher',
            'type': 'image',
            'timestamp': 1000,
            'fileSize': 42,
          },
        ],
        localUserId: 'me',
        cache: {},
        loadReactionsForMessages: _noReactions,
        readReceiptsEnabled: false,
      );

      final msg = result.single as ImageMessage;
      expect(msg.size, 42);
      expect(msg.source, deferredImageSourceFor('m-img'));
    });

    test('a viewOnce+viewed image row becomes a size-0 empty-source placeholder',
        () async {
      final result = await mapper.mapDirectRows(
        [
          {
            'id': 'm-img2',
            'senderId': 'peer',
            'receiverId': 'me',
            'message': 'cipher',
            'type': 'image',
            'timestamp': 1000,
            'viewOnce': 1,
            'viewed': 1,
          },
        ],
        localUserId: 'me',
        cache: {},
        loadReactionsForMessages: _noReactions,
        readReceiptsEnabled: false,
      );

      final msg = result.single as ImageMessage;
      expect(msg.size, 0);
      expect(msg.source, '');
    });

    test('reactions are attached via the injected loader', () async {
      final wire = await keyManager.encryptForSelf('with reaction');
      final result = await mapper.mapDirectRows(
        [
          {
            'id': 'm-react',
            'senderId': 'me',
            'receiverId': 'peer',
            'message': wire,
            'type': 'text',
            'timestamp': 1000,
            'status': 'sent',
          },
        ],
        localUserId: 'me',
        cache: {},
        loadReactionsForMessages: (ids) async => {
          'm-react': {
            '👍': ['peer'],
          },
        },
        readReceiptsEnabled: false,
      );

      expect(result.single.reactions, {
        '👍': ['peer'],
      });
    });

    test('outbound status is attached to the sender\'s own rows', () async {
      final wire = await keyManager.encryptForSelf('outbound text');
      final result = await mapper.mapDirectRows(
        [
          {
            'id': 'm-out',
            'senderId': 'me',
            'receiverId': 'peer',
            'message': wire,
            'type': 'text',
            'timestamp': 1000,
            'status': 'sent',
          },
        ],
        localUserId: 'me',
        cache: {},
        loadReactionsForMessages: _noReactions,
        readReceiptsEnabled: true,
      );

      expect(result.single.sentAt, isNotNull);
    });
  });

  group('decryptGroupFileBytes', () {
    test('decrypts bytes using the injected group-key getter', () async {
      final groupKey = Uint8List.fromList(List.generate(32, (i) => i));
      final wire = await GroupCryptoV2.encryptGroupFile(
        groupKey,
        Uint8List.fromList([9, 8, 7]),
      );
      final bytes = await mapper.decryptGroupFileBytes(
        getDecryptedGroupKey: (groupId) async => groupKey,
        groupId: 'group-1',
        row: {'message': wire},
      );
      expect(bytes, [9, 8, 7]);
    });

    test('throws when no group key is available', () {
      expect(
        () => mapper.decryptGroupFileBytes(
          getDecryptedGroupKey: (groupId) async => null,
          groupId: 'group-1',
          row: {'message': 'cipher'},
        ),
        throwsException,
      );
    });
  });
}
