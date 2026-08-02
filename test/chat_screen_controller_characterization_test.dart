// Characterization tests for Fase 6B: pin down the current (pre-controller)
// behaviour of the riskiest areas duplicated between `_ChatScreenState`
// (lib/screens/chat.dart) and `_GroupChatScreenState`
// (lib/screens/group_chat.dart), per the Fase 6B brief:
//   - reply draft persist/restore (dm:/group: keys)
//   - typing event handling
//   - reaction apply
//   - read receipt apply (incl. the DM=1 vs group=memberCount-1
//     requiredReadCount divergence)
//   - pagination batch
//
// Both State classes keep this logic in private methods, so — same
// convention as Fase 6A's message_actions_characterization_test.dart /
// message_view_mapper_characterization_test.dart — this file transcribes
// each method body verbatim (comment marks the exact source lines) and
// drives it against real collaborators (MessageDraftStore, TypingStateTracker,
// real in-memory sqflite). ChatScreenController does not exist yet as far as
// this file is concerned; it is the baseline `chat_screen_controller_test.dart`
// is checked against.
import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/database/message_read_receipts.dart';
import 'package:prysm/database/messages.dart';
import 'package:prysm/models/chat/prysm_message.dart';
import 'package:prysm/models/reply_preview_data.dart';
import 'package:prysm/screens/widgets/message_reaction_bar.dart';
import 'package:prysm/services/message_draft_store.dart';
import 'package:prysm/services/reaction_service.dart';
import 'package:prysm/services/typing_state_tracker.dart';
import 'package:prysm/ui/chat/prysm_chat_message_list.dart';
import 'package:prysm/util/outbound_read_status_refresh.dart';
import 'package:prysm/util/reply_preview_label.dart';
import 'package:prysm/util/typing_indicator_notifier.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<Database> _openMessagesDb() async {
  final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
  await db.execute('''
    CREATE TABLE messages(
      id TEXT PRIMARY KEY,
      senderId TEXT NOT NULL,
      receiverId TEXT NOT NULL,
      message TEXT,
      type TEXT,
      fileName TEXT,
      fileSize INTEGER,
      timestamp INTEGER NOT NULL,
      status TEXT DEFAULT 'sent',
      replyTo TEXT,
      readAt INTEGER,
      viewOnce INTEGER DEFAULT 0,
      viewed INTEGER DEFAULT 0,
      groupId TEXT,
      deletedAt INTEGER,
      editedAt INTEGER,
      expiresAt INTEGER
    )
  ''');
  await MessageReadReceiptsDb.createTable(db);
  return db;
}

// ===========================================================================
// 1. Reply draft persist/restore — chat.dart:195-234 / group_chat.dart:168-207
//    (identical bodies; only `_draftKey` differs: 'dm:$peerId' vs
//    'group:${group.id}').
// ===========================================================================

class _ReplyDraftHarness {
  _ReplyDraftHarness(this.draftKey);

  final String draftKey;
  final List<Message> messages = [];
  Message? replyToMessage;
  ReplyPreviewData? replyDraft;

  void persistReplyDraft() {
    final data = replyToMessage != null
        ? replyPreviewFromMessage(replyToMessage!)
        : replyDraft;
    MessageDraftStore.instance.setReply(draftKey, data);
  }

  void restoreReplyDraft() {
    final stored = MessageDraftStore.instance.get(draftKey).reply;
    if (stored == null) return;
    Message? found;
    for (final message in messages) {
      if (message.id == stored.messageId) {
        found = message;
        break;
      }
    }
    replyToMessage = found;
    replyDraft = found == null ? stored : null;
  }

  void clearReplyState() {
    replyToMessage = null;
    replyDraft = null;
    MessageDraftStore.instance.setReply(draftKey, null);
  }

  void setReplyToMessage(Message message) {
    replyToMessage = message;
    replyDraft = null;
    persistReplyDraft();
  }
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  tearDown(() => MessageDraftStore.instance.clearAll());

  group('reply draft persist/restore (dm:/group: keys)', () {
    test('dm: and group: keys are independent', () {
      final dm = _ReplyDraftHarness('dm:peer-1');
      final grp = _ReplyDraftHarness('group:group-1');
      final msg = TextMessage(
        id: 'm1',
        authorId: 'peer-1',
        text: 'hi',
        createdAt: DateTime.now(),
      );
      dm.messages.add(msg);
      grp.messages.add(msg);

      dm.setReplyToMessage(msg);

      expect(MessageDraftStore.instance.get('dm:peer-1').reply?.messageId, 'm1');
      expect(MessageDraftStore.instance.get('group:group-1').reply, isNull);

      grp.setReplyToMessage(msg);
      expect(MessageDraftStore.instance.get('group:group-1').reply?.messageId, 'm1');
    });

    test('restoreReplyDraft finds the message in the current list', () {
      final harness = _ReplyDraftHarness('dm:peer-1');
      final msg = TextMessage(
        id: 'm1',
        authorId: 'peer-1',
        text: 'hi',
        createdAt: DateTime.now(),
      );
      MessageDraftStore.instance.setReply(
        'dm:peer-1',
        replyPreviewFromMessage(msg),
      );
      harness.messages.add(msg);

      harness.restoreReplyDraft();

      expect(harness.replyToMessage?.id, 'm1');
      expect(harness.replyDraft, isNull);
    });

    test('restoreReplyDraft falls back to raw draft when message is gone', () {
      final harness = _ReplyDraftHarness('group:group-1');
      const stored = ReplyPreviewData(
        messageId: 'missing',
        authorId: 'peer-1',
        label: 'Hello',
        kind: ReplyPreviewKind.text,
      );
      MessageDraftStore.instance.setReply('group:group-1', stored);

      harness.restoreReplyDraft();

      expect(harness.replyToMessage, isNull);
      expect(harness.replyDraft?.messageId, 'missing');
    });

    test('clearReplyState nulls local state and the store', () {
      final harness = _ReplyDraftHarness('dm:peer-1');
      final msg = TextMessage(
        id: 'm1',
        authorId: 'peer-1',
        text: 'hi',
        createdAt: DateTime.now(),
      );
      harness.setReplyToMessage(msg);

      harness.clearReplyState();

      expect(harness.replyToMessage, isNull);
      expect(harness.replyDraft, isNull);
      expect(MessageDraftStore.instance.get('dm:peer-1').reply, isNull);
    });
  });

  // =========================================================================
  // 2. Typing event handling — chat.dart:431-449 / group_chat.dart:404-422.
  // =========================================================================

  group('typing event handling', () {
    late TypingStateTracker tracker;

    setUp(() => tracker = TypingStateTracker());
    tearDown(() => tracker.dispose());

    // Mirrors _ChatScreenState._onTypingEvent (chat.dart:431-441).
    void dmOnTypingEvent(
      TypingStateTracker tracker,
      String peerId,
      TypingIndicatorEvent event,
    ) {
      if (event.groupId != null) return;
      if (event.senderId != peerId) return;
      tracker.applyEvent(
        conversationKey: peerId,
        senderId: event.senderId,
        typing: event.typing,
        timestamp: event.timestamp,
      );
    }

    // Mirrors _GroupChatScreenState._onTypingEvent (group_chat.dart:404-414).
    void groupOnTypingEvent(
      TypingStateTracker tracker,
      String groupId,
      String userId,
      TypingIndicatorEvent event,
    ) {
      if (event.groupId != groupId) return;
      if (event.senderId == userId) return;
      tracker.applyEvent(
        conversationKey: groupId,
        senderId: event.senderId,
        typing: event.typing,
        timestamp: event.timestamp,
      );
    }

    test('dm ignores group events and non-peer senders', () {
      final now = DateTime.now().millisecondsSinceEpoch;
      dmOnTypingEvent(
        tracker,
        'peer-1',
        TypingIndicatorEvent(senderId: 'peer-1', groupId: 'g1', peerId: null, typing: true, timestamp: now),
      );
      expect(tracker.activeTypists('peer-1'), isEmpty);

      dmOnTypingEvent(
        tracker,
        'peer-1',
        TypingIndicatorEvent(senderId: 'someone-else', groupId: null, peerId: 'peer-1', typing: true, timestamp: now),
      );
      expect(tracker.activeTypists('peer-1'), isEmpty);
    });

    test('dm records a matching peer event', () {
      final now = DateTime.now().millisecondsSinceEpoch;
      dmOnTypingEvent(
        tracker,
        'peer-1',
        TypingIndicatorEvent(senderId: 'peer-1', groupId: null, peerId: 'peer-1', typing: true, timestamp: now),
      );
      expect(tracker.activeTypists('peer-1'), ['peer-1']);
    });

    test('group ignores foreign groups and self events', () {
      final now = DateTime.now().millisecondsSinceEpoch;
      groupOnTypingEvent(
        tracker,
        'g1',
        'me',
        TypingIndicatorEvent(senderId: 'other', groupId: 'g2', peerId: null, typing: true, timestamp: now),
      );
      expect(tracker.activeTypists('g1'), isEmpty);

      groupOnTypingEvent(
        tracker,
        'g1',
        'me',
        TypingIndicatorEvent(senderId: 'me', groupId: 'g1', peerId: null, typing: true, timestamp: now),
      );
      expect(tracker.activeTypists('g1'), isEmpty);
    });

    test('group records a matching member event', () {
      final now = DateTime.now().millisecondsSinceEpoch;
      groupOnTypingEvent(
        tracker,
        'g1',
        'me',
        TypingIndicatorEvent(senderId: 'other', groupId: 'g1', peerId: null, typing: true, timestamp: now),
      );
      expect(tracker.activeTypists('g1'), ['other']);
    });
  });

  // =========================================================================
  // 3. Reaction apply — chat.dart:788-799 / group_chat.dart:623-633
  //    (identical apart from DM's extra `_messageCache` write).
  // =========================================================================

  group('reaction apply', () {
    // Mirrors _ChatScreenState/_GroupChatScreenState._applyReactionUpdate.
    void applyReactionUpdate(
      PrysmChatMessageList messages,
      ReactionUpdate update,
      Map<String, Message>? messageCache,
    ) {
      try {
        final msg = messages.messages.firstWhere((m) => m.id == update.targetMessageId);
        final updated = applyReactionsToMessage(msg, update.reactions);
        messages.updateMessage(msg, updated);
        messageCache?[msg.id] = updated;
      } catch (_) {}
    }

    test('updates reactions on the target message', () {
      final messages = PrysmChatMessageList(messages: [
        TextMessage(id: 'm1', authorId: 'peer', text: 'hi', createdAt: DateTime.now()),
      ]);
      final cache = <String, Message>{};

      applyReactionUpdate(
        messages,
        const ReactionUpdate(targetMessageId: 'm1', reactions: {'👍': ['peer']}),
        cache,
      );

      expect(messages.messages.single.reactions, {'👍': ['peer']});
      expect(cache['m1']?.reactions, {'👍': ['peer']});
    });

    test('missing target message is a silent no-op', () {
      final messages = PrysmChatMessageList(messages: [
        TextMessage(id: 'm1', authorId: 'peer', text: 'hi', createdAt: DateTime.now()),
      ]);

      applyReactionUpdate(
        messages,
        const ReactionUpdate(targetMessageId: 'missing', reactions: {'👍': ['peer']}),
        null,
      );

      expect(messages.messages.single.reactions, isNull);
    });
  });

  // =========================================================================
  // 4. Read receipt apply — chat.dart:505-560 / group_chat.dart:746-796.
  // =========================================================================

  group('read receipt apply', () {
    late Database db;

    setUp(() async {
      db = await _openMessagesDb();
      MessagesDb.setDatabaseForTest(db);
    });

    tearDown(() async {
      await db.close();
      MessagesDb.setDatabaseForTest(null);
    });

    test('markInboundConversationRead returns a waterline for the newest unread', () async {
      await db.insert('messages', {
        'id': 'm1', 'senderId': 'peer-1', 'receiverId': 'me',
        'message': 'a', 'type': 'text', 'timestamp': 1000, 'status': 'received',
      });
      await db.insert('messages', {
        'id': 'm2', 'senderId': 'peer-1', 'receiverId': 'me',
        'message': 'b', 'type': 'text', 'timestamp': 2000, 'status': 'received',
      });

      final waterline = await MessagesDb.markInboundConversationRead('me', 'peer-1');

      expect(waterline, isNotNull);
      expect(waterline!.latestMessageId, 'm2');
      expect(waterline.readUpToTimestamp, 2000);
    });

    test('markInboundGroupRead ignores own messages and returns null when nothing unread', () async {
      await db.insert('messages', {
        'id': 'g1::m1', 'senderId': 'me', 'receiverId': 'me',
        'message': 'a', 'type': 'text', 'timestamp': 1000, 'status': 'received', 'groupId': 'g1',
      });

      final waterline = await MessagesDb.markInboundGroupRead('me', 'g1');

      expect(waterline, isNull);
    });

    test('dm applyReadReceiptUpdate uses requiredReadCount=1', () async {
      await MessageReadReceiptsDb.upsertReceipt(
        wireMessageId: 'out1',
        readerId: 'peer-1',
        readAt: 5000,
      );
      final outbound = TextMessage(
        id: 'out1',
        authorId: 'me',
        text: 'hi',
        createdAt: DateTime.now(),
        sentAt: DateTime.now(),
      );

      // Mirrors _ChatScreenState._applyReadReceiptUpdate's refreshOutboundReadStatus
      // call (chat.dart:531-536): no groupId, requiredReadCount hardcoded to 1.
      final refreshed = await refreshOutboundReadStatus(
        messages: [outbound],
        localUserId: 'me',
        readReceiptsEnabled: true,
        requiredReadCount: 1,
      );

      expect(refreshed.single.seenAt, isNotNull);
    });

    test('group applyReadReceiptUpdate requires memberCount-1 readers', () async {
      // Only 1 of 2 other members has read it — group.dart:772's
      // requiredReadCount = memberCount>1 ? memberCount-1 : 1 with
      // memberCount=3 means 2 readers are required.
      await MessageReadReceiptsDb.upsertReceipt(
        wireMessageId: 'out1',
        readerId: 'member-a',
        readAt: 5000,
        groupId: 'g1',
      );
      final outbound = TextMessage(
        id: 'out1',
        authorId: 'me',
        text: 'hi',
        createdAt: DateTime.now(),
        sentAt: DateTime.now(),
      );

      final partiallyRead = await refreshOutboundReadStatus(
        messages: [outbound],
        localUserId: 'me',
        readReceiptsEnabled: true,
        groupId: 'g1',
        requiredReadCount: 2,
      );
      expect(partiallyRead.single.seenAt, isNull);

      await MessageReadReceiptsDb.upsertReceipt(
        wireMessageId: 'out1',
        readerId: 'member-b',
        readAt: 5100,
        groupId: 'g1',
      );

      final fullyRead = await refreshOutboundReadStatus(
        messages: [outbound],
        localUserId: 'me',
        readReceiptsEnabled: true,
        groupId: 'g1',
        requiredReadCount: 2,
      );
      expect(fullyRead.single.seenAt, isNotNull);
    });
  });

  // =========================================================================
  // 5. Pagination batch — chat.dart:1006-1048 / group_chat.dart:1036-1078.
  // =========================================================================

  group('pagination batch', () {
    late Database db;

    setUp(() async {
      db = await _openMessagesDb();
      MessagesDb.setDatabaseForTest(db);
    });

    tearDown(() async {
      await db.close();
      MessagesDb.setDatabaseForTest(null);
    });

    Future<void> seedDirect(int count) async {
      for (var i = 0; i < count; i++) {
        await db.insert('messages', {
          'id': 'm$i', 'senderId': 'peer-1', 'receiverId': 'me',
          'message': 'text $i', 'type': 'text', 'timestamp': 1000 + i, 'status': 'received',
        });
      }
    }

    test('dm getMessagesBetweenBatchWithId pages oldest-first cursor, newest-first order', () async {
      await seedDirect(25);

      final page1 = await MessagesDb.getMessagesBetweenBatchWithId('me', 'peer-1', limit: 20);
      expect(page1.length, 20);
      // DESC order: newest (m24) first.
      expect(page1.first['id'], 'm24');

      final oldest = page1.last;
      final page2 = await MessagesDb.getMessagesBetweenBatchWithId(
        'me',
        'peer-1',
        limit: 20,
        beforeTimestamp: oldest['timestamp'] as int,
        beforeId: oldest['id'] as String,
      );
      // Remaining 5 messages (m0-m4), no overlap with page1.
      expect(page2.length, 5);
      expect(page2.map((r) => r['id']), isNot(contains(oldest['id'])));
    });

    test('group getMessagesForGroupBatch honors afterTimestamp (join time)', () async {
      // Messages before the local user joined must not page in — mirrors
      // group_chat.dart:1045's `afterTimestamp: _joinedAt`.
      await db.insert('messages', {
        'id': 'pre-join', 'senderId': 'other', 'receiverId': 'other',
        'message': 'old', 'type': 'text', 'timestamp': 500, 'status': 'received', 'groupId': 'g1',
      });
      await db.insert('messages', {
        'id': 'post-join', 'senderId': 'other', 'receiverId': 'other',
        'message': 'new', 'type': 'text', 'timestamp': 1500, 'status': 'received', 'groupId': 'g1',
      });

      final batch = await MessagesDb.getMessagesForGroupBatch(
        'g1',
        limit: 20,
        afterTimestamp: 1000,
      );

      expect(batch.map((r) => r['id']), ['post-join']);
    });

    test('a short batch (< page size) signals no more history', () async {
      await seedDirect(3);

      final batch = await MessagesDb.getMessagesBetweenBatchWithId('me', 'peer-1', limit: 20);

      expect(batch.length, lessThan(20));
      // _loadMoreMessages (chat.dart:1020-1021 / group_chat.dart:1050) reads
      // this as the hasMore=false signal.
    });
  });
}
