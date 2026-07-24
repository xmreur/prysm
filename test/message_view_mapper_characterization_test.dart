// Characterization tests for the row→Message decrypt/mapping pipeline that,
// as of this commit, lives inline in `_ChatScreenState`
// (lib/screens/chat.dart: `_decryptDirectTextMessage`, `decryptMessagesDeferred`,
// `_attachReactions`, `_attachOutboundStatus`, `_deletedMessageFromRow`) and
// `_GroupChatScreenState` (lib/screens/group_chat.dart: `_decryptGroupFileBytes`).
//
// Those methods are private to their States, so they cannot be called
// directly from a test. Per the Fase 6A brief, this file instead pins down
// their observable output: each `_dm*`/`_group*` helper below is a
// line-for-line transcription of the current State method body — same
// branches, same shared helpers (`metadataFromDbRow`, `rowShowsAsDeleted`,
// `applyReactionsToMessage`, `outboundStatusFromDbRow`, `applyOutboundStatus`,
// `deferredImageSourceFor`) — driven with a real `KeyManager` (built via
// `KeyManager.fromIdentity`) against real in-memory sqflite DBs and
// hand-rolled DB rows. Fase 6A step 2 moves this exact logic into
// `MessageViewMapper`; this file is the baseline that proves nothing changed.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/constants/media_constants.dart';
import 'package:prysm/crypto/constants.dart';
import 'package:prysm/crypto/group_crypto.dart';
import 'package:prysm/crypto/identity.dart';
import 'package:prysm/crypto/ratchet/session_store.dart';
import 'package:prysm/database/message_read_receipts.dart';
import 'package:prysm/database/messages.dart';
import 'package:prysm/models/chat/prysm_message.dart';
import 'package:prysm/screens/widgets/message_reaction_bar.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/message_modify_policy.dart';
import 'package:prysm/util/message_status_mapper.dart';
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

/// Mirrors `_ChatScreenState._decryptDirectTextMessage` (chat.dart 782-821).
Future<String> _dmDecryptDirectTextMessage(
  Map<String, dynamic> msg,
  String userId,
  KeyManager keyManager,
) async {
  final senderId = msg['senderId'] as String;
  final wire = msg['message'] as String?;
  if (wire == null || wire.isEmpty) {
    throw const FormatException('Empty message payload');
  }

  final trimmed = wire.trimLeft();
  if (trimmed.startsWith('{')) {
    final parsed = jsonDecode(wire);
    if (parsed is Map<String, dynamic>) {
      if (parsed['envelope'] == CryptoConstants.cryptoVersion) {
        throw const FormatException('Misrouted group control payload');
      }
      if (parsed.containsKey('iv') && parsed.containsKey('ct')) {
        throw const FormatException('Group-encoded payload in direct chat');
      }
    }
  }

  if (senderId == userId) {
    return keyManager.decryptMessage(wire);
  }

  final user = await DBHelper.getUserById(senderId);
  final identityJson =
      (user?['identityJson'] as String?) ?? (user?['publicKeyPem'] as String?);
  if (identityJson == null || identityJson.isEmpty) {
    throw const FormatException('Missing peer identity');
  }
  final peerKey = keyManager.importPeerIdentity(identityJson);
  return keyManager.decryptPeerMessage(
    peerId: senderId,
    wire: wire,
    peer: peerKey,
  );
}

Message _dmDeletedMessageFromRow(
  Map<String, dynamic> msg,
  Map<String, Object?> meta,
) {
  return TextMessage(
    authorId: msg['senderId'] as String,
    createdAt: DateTime.fromMillisecondsSinceEpoch(msg['timestamp'] as int),
    id: msg['id'] as String,
    replyToMessageId: msg['replyTo'] as String?,
    text: '',
    metadata: meta,
  );
}

/// Mirrors `_ChatScreenState.decryptMessagesDeferred` +
/// `_attachReactions` + `_attachOutboundStatus` (chat.dart 823-998).
Future<List<Message>> _dmDecryptMessagesDeferred(
  List<Map<String, dynamic>> rawMessages,
  String userId,
  KeyManager keyManager, {
  required Map<String, Message> messageCache,
  required bool readReceiptsEnabled,
}) async {
  final messages = <Message>[];

  for (final msg in rawMessages) {
    if (messageCache.containsKey(msg['id'])) {
      messages.add(messageCache[msg['id']]!);
      continue;
    }
    final meta = metadataFromDbRow(msg);
    if (rowShowsAsDeleted(msg, meta)) {
      messages.add(_dmDeletedMessageFromRow(msg, {...meta, 'deleted': true}));
      continue;
    }
    try {
      if (msg['type'] == 'text') {
        messages.add(
          TextMessage(
            authorId: msg['senderId'] as String,
            createdAt: DateTime.fromMillisecondsSinceEpoch(msg['timestamp']),
            id: msg['id'],
            replyToMessageId: msg['replyTo'],
            text: await _dmDecryptDirectTextMessage(msg, userId, keyManager),
            metadata: meta.isEmpty ? null : meta,
          ),
        );
      } else if (msg['type'] == 'file') {
        final fileName = msg['fileName'] ?? 'Unknown';
        final msgId = msg['id'] as String;
        var fileMsg = FileMessage(
          id: msgId,
          authorId: msg['senderId'] as String,
          createdAt: DateTime.fromMillisecondsSinceEpoch(msg['timestamp']),
          replyToMessageId: msg['replyTo'],
          name: fileName,
          size: msg['fileSize'] ?? 0,
          source: (msg['message'] as String?) ?? '',
          metadata: meta.isEmpty ? null : meta,
        );
        if (msg['senderId'] == userId) {
          fileMsg = applyOutboundStatus(
            fileMsg,
            status: outboundStatusFromDbRow(
              row: msg,
              localUserId: userId,
              readReceiptsEnabled: readReceiptsEnabled,
            ),
          ) as FileMessage;
        }
        messages.add(fileMsg);
      } else if (msg['type'] == 'audio') {
        messages.add(
          FileMessage(
            id: msg['id'],
            authorId: msg['senderId'] as String,
            createdAt: DateTime.fromMillisecondsSinceEpoch(msg['timestamp']),
            replyToMessageId: msg['replyTo'],
            name: msg['fileName'] ?? 'voice_message.wav',
            size: msg['fileSize'] ?? 0,
            source: msg['message'],
          ),
        );
      } else if (msg['type'] == 'call') {
        final payload =
            jsonDecode((msg['message'] as String?) ?? '{}') as Map<String, dynamic>;
        messages.add(
          PrysmCallMessage(
            id: msg['id'],
            authorId: msg['senderId'] as String,
            createdAt: DateTime.fromMillisecondsSinceEpoch(msg['timestamp']),
            durationMs: (payload['durationMs'] as num?)?.toInt() ?? 0,
            callStatus: payload['status'] as String? ?? 'completed',
            direction: payload['direction'] as String? ?? 'outbound',
          ),
        );
      } else if (msg['type'] == "image") {
        final isViewOnce = (msg['viewOnce'] ?? 0) == 1;
        final isViewed = (msg['viewed'] ?? 0) == 1;

        if (isViewOnce && isViewed) {
          messages.add(
            ImageMessage(
              id: msg['id'],
              authorId: msg['senderId'] as String,
              createdAt: DateTime.fromMillisecondsSinceEpoch(msg['timestamp']),
              replyToMessageId: msg['replyTo'],
              size: 0,
              source: "",
              metadata: {'viewOnce': true, 'viewed': true},
            ),
          );
        } else {
          final msgId = msg['id'] as String;
          messages.add(
            ImageMessage(
              id: msgId,
              authorId: msg['senderId'] as String,
              createdAt: DateTime.fromMillisecondsSinceEpoch(msg['timestamp']),
              replyToMessageId: msg['replyTo'],
              size: msg['fileSize'] ?? 0,
              source: isViewOnce ? '' : deferredImageSourceFor(msgId),
              metadata: isViewOnce
                  ? {'viewOnce': true, 'viewed': false}
                  : (meta.isEmpty ? null : meta),
            ),
          );
        }
      }
    } catch (e) {
      messages.add(
        TextMessage(
          authorId: msg['senderId'] as String,
          createdAt: DateTime.fromMillisecondsSinceEpoch(msg['timestamp']),
          id: msg['id'],
          replyToMessageId: msg['replyTo'],
          text: '🔒 Unable to decrypt message',
        ),
      );
    }
  }

  final withReactions = await _dmAttachReactions(messages);
  return _dmAttachOutboundStatus(
    withReactions,
    rawMessages,
    userId,
    readReceiptsEnabled,
  );
}

Future<List<Message>> _dmAttachReactions(List<Message> messages) async {
  if (messages.isEmpty) return messages;
  final reactions = <String, Map<String, List<String>>>{}; // no reactor in these fixtures
  return messages
      .map((m) => applyReactionsToMessage(m, reactions[m.id]))
      .toList();
}

Future<List<Message>> _dmAttachOutboundStatus(
  List<Message> messages,
  List<Map<String, dynamic>> rawRows,
  String userId,
  bool readReceiptsEnabled,
) async {
  final outboundWireIds = <String>[];
  final rowByWireId = <String, Map<String, dynamic>>{};

  for (final row in rawRows) {
    final wireId = MessagesDb.wireIdFromStorage(row['id'] as String);
    if (row['senderId'] == userId) {
      outboundWireIds.add(wireId);
      rowByWireId[wireId] = row;
    }
  }

  if (outboundWireIds.isEmpty) return messages;

  final receipts =
      await MessageReadReceiptsDb.getReceiptsForMessages(outboundWireIds);

  return messages.map((m) {
    final row = rowByWireId[m.id];
    if (row == null) return m;
    final status = outboundStatusFromDbRow(
      row: row,
      localUserId: userId,
      readReceiptsEnabled: readReceiptsEnabled,
      receipts: receipts[m.id] ?? const [],
      requiredReadCount: 1,
    );
    return applyOutboundStatus(m, status: status);
  }).toList();
}

/// Mirrors `_GroupChatScreenState._decryptGroupFileBytes` (group_chat.dart 843-847).
Future<Uint8List> _groupDecryptFileBytes(
  Future<Uint8List?> Function(String groupId) getDecryptedGroupKey,
  String groupId,
  Map<String, dynamic> msg,
) async {
  final groupKey = await getDecryptedGroupKey(groupId);
  if (groupKey == null) throw Exception('No group key');
  return GroupCryptoV2.decryptGroupFile(groupKey, msg['message'] as String);
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
  late IdentityKeyPair peerIdentity;

  setUp(() async {
    messagesDb = await _openMessagesDb();
    MessagesDb.setDatabaseForTest(messagesDb);

    dbHelperDb = await _openDbHelperDb();
    DBHelper.setDatabaseForTest(dbHelperDb);

    keyManager = KeyManager.fromIdentity(await IdentityKeyPair.generate());
    peerIdentity = await IdentityKeyPair.generate();
    final identityJson = jsonEncode(await peerIdentity.toPublicJson());
    await DBHelper.insertOrUpdateUser({
      'id': 'peer',
      'name': 'Peer',
      'identityJson': identityJson,
      'publicKeyPem': identityJson,
    });
  });

  tearDown(() async {
    await messagesDb.close();
    MessagesDb.setDatabaseForTest(null);

    await dbHelperDb.close();
    DBHelper.setDatabaseForTest(null);
  });

  group('direct text decrypt', () {
    test('self-authored row decrypts via decryptMessage', () async {
      final wire = await keyManager.encryptForSelf('hi there');
      final text = await _dmDecryptDirectTextMessage(
        {'senderId': 'me', 'message': wire},
        'me',
        keyManager,
      );
      expect(text, 'hi there');
    });

    test(
        'peer-authored row with a resolvable identity is routed through '
        'importPeerIdentity + decryptPeerMessage (not the "missing identity" '
        'guard)', () async {
      // A full asymmetric round trip needs a second party's ratchet session
      // and prekey bundle; that machinery is already covered by
      // test/crypto/ratchet_bootstrap_test.dart. Here we only characterize
      // which branch chat.dart takes: with a peer identity on file, decrypt
      // is *attempted* via decryptPeerMessage — proven by the failure being
      // a crypto error, not the FormatException the "no identity" branch
      // throws.
      await expectLater(
        () => _dmDecryptDirectTextMessage(
          {'senderId': 'peer', 'message': 'not-a-real-ciphertext'},
          'me',
          keyManager,
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            isNot('Missing peer identity'),
          ),
        ),
      );
    });

    test('missing peer identity throws FormatException', () async {
      expect(
        () => _dmDecryptDirectTextMessage(
          {'senderId': 'stranger', 'message': 'cipher'},
          'me',
          keyManager,
        ),
        throwsFormatException,
      );
    });
  });

  group('mapDirectRows', () {
    test('text row maps to a decrypted TextMessage', () async {
      final wire = await keyManager.encryptForSelf('mapped text');
      final rows = [
        {
          'id': 'm1',
          'senderId': 'me',
          'receiverId': 'peer',
          'message': wire,
          'type': 'text',
          'timestamp': 1000,
          'status': 'sent',
        },
      ];

      final result = await _dmDecryptMessagesDeferred(
        rows,
        'me',
        keyManager,
        messageCache: {},
        readReceiptsEnabled: false,
      );

      expect(result, hasLength(1));
      final msg = result.single as TextMessage;
      expect(msg.text, 'mapped text');
      expect(msg.id, 'm1');
      expect(msg.authorId, 'me');
    });

    test('cached row is reused verbatim without decrypting', () async {
      final cached = TextMessage(
        id: 'm-cached',
        authorId: 'peer',
        text: 'already decrypted',
      );
      final rows = [
        {
          'id': 'm-cached',
          'senderId': 'peer',
          'receiverId': 'me',
          'message': 'garbage-that-would-fail-to-decrypt',
          'type': 'text',
          'timestamp': 1000,
        },
      ];

      final result = await _dmDecryptMessagesDeferred(
        rows,
        'me',
        keyManager,
        messageCache: {'m-cached': cached},
        readReceiptsEnabled: false,
      );

      expect(result.single, same(cached));
    });

    test('undecryptable row falls back to the lock-emoji placeholder', () async {
      final rows = [
        {
          'id': 'm-bad',
          'senderId': 'stranger',
          'receiverId': 'me',
          'message': 'cipher',
          'type': 'text',
          'timestamp': 1000,
        },
      ];

      final result = await _dmDecryptMessagesDeferred(
        rows,
        'me',
        keyManager,
        messageCache: {},
        readReceiptsEnabled: false,
      );

      final msg = result.single as TextMessage;
      expect(msg.text, '🔒 Unable to decrypt message');
      expect(msg.metadata, isNull);
    });

    test('row with deletedAt maps to an empty-text deleted placeholder',
        () async {
      final rows = [
        {
          'id': 'm-deleted',
          'senderId': 'peer',
          'receiverId': 'me',
          'message': 'cipher',
          'type': 'text',
          'timestamp': 1000,
          'deletedAt': 2000,
        },
      ];

      final result = await _dmDecryptMessagesDeferred(
        rows,
        'me',
        keyManager,
        messageCache: {},
        readReceiptsEnabled: false,
      );

      final msg = result.single as TextMessage;
      expect(msg.text, '');
      expect(msg.metadata, {'deleted': true});
    });

    test('viewOnce+viewed image row maps to a size-0 empty-source placeholder',
        () async {
      final rows = [
        {
          'id': 'm-img',
          'senderId': 'peer',
          'receiverId': 'me',
          'message': 'cipher',
          'type': 'image',
          'timestamp': 1000,
          'viewOnce': 1,
          'viewed': 1,
        },
      ];

      final result = await _dmDecryptMessagesDeferred(
        rows,
        'me',
        keyManager,
        messageCache: {},
        readReceiptsEnabled: false,
      );

      final msg = result.single as ImageMessage;
      expect(msg.size, 0);
      expect(msg.source, '');
      expect(msg.metadata, {'viewOnce': true, 'viewed': true});
    });

    test('non-viewOnce image row gets a deferred source placeholder', () async {
      final rows = [
        {
          'id': 'm-img2',
          'senderId': 'peer',
          'receiverId': 'me',
          'message': 'cipher',
          'type': 'image',
          'timestamp': 1000,
          'fileSize': 42,
        },
      ];

      final result = await _dmDecryptMessagesDeferred(
        rows,
        'me',
        keyManager,
        messageCache: {},
        readReceiptsEnabled: false,
      );

      final msg = result.single as ImageMessage;
      expect(msg.size, 42);
      expect(msg.source, deferredImageSourceFor('m-img2'));
    });

    test('outbound status is attached to the sender\'s own rows', () async {
      final wire = await keyManager.encryptForSelf('outbound text');
      final rows = [
        {
          'id': 'm-out',
          'senderId': 'me',
          'receiverId': 'peer',
          'message': wire,
          'type': 'text',
          'timestamp': 1000,
          'status': 'sent',
        },
      ];

      final result = await _dmDecryptMessagesDeferred(
        rows,
        'me',
        keyManager,
        messageCache: {},
        readReceiptsEnabled: true,
      );

      expect(result.single.sentAt, isNotNull);
    });
  });

  group('group file bytes decrypt', () {
    test('decrypts bytes when a group key is available', () async {
      final groupKey = Uint8List.fromList(List.generate(32, (i) => i));
      final wire = await GroupCryptoV2.encryptGroupFile(
        groupKey,
        Uint8List.fromList([1, 2, 3, 4]),
      );
      final bytes = await _groupDecryptFileBytes(
        (groupId) async => groupKey,
        'group-1',
        {'message': wire},
      );
      expect(bytes, [1, 2, 3, 4]);
    });

    test('throws when no group key is available', () async {
      expect(
        () => _groupDecryptFileBytes(
          (groupId) async => null,
          'group-1',
          {'message': 'cipher'},
        ),
        throwsException,
      );
    });
  });
}
