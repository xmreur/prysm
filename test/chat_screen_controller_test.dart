// Unit tests for ChatScreenController (Fase 6B): the single, parametrized
// controller extracted from _ChatScreenState/_GroupChatScreenState. See
// chat_screen_controller_characterization_test.dart for the pre-refactor
// baseline these tests are checked against — these exercise the real class
// directly, with hand-written fakes for the network-facing collaborators
// (ReactionService/ReadReceiptService are subclassed to record calls instead
// of touching the transport; TypingIndicatorService uses its own
// `sendOverride` testing seam) and a real in-memory sqflite DB for the parts
// that genuinely hit the database (read receipts, i.e. `MessageReadReceiptsDb`).
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/crypto/identity.dart';
import 'package:prysm/database/message_read_receipts.dart';
import 'package:prysm/database/messages.dart';
import 'package:prysm/models/chat/prysm_message.dart';
import 'package:prysm/models/reply_preview_data.dart';
import 'package:prysm/services/chat_screen_controller.dart';
import 'package:prysm/services/message_draft_store.dart';
import 'package:prysm/services/reaction_service.dart';
import 'package:prysm/services/read_receipt_service.dart';
import 'package:prysm/services/typing_indicator_service.dart';
import 'package:prysm/services/typing_state_tracker.dart';
import 'package:prysm/ui/chat/prysm_chat_message_list.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/read_waterline_mark.dart';
import 'package:prysm/util/typing_indicator_notifier.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void _mockPathProvider() {
  final tempDir = Directory.systemTemp.createTempSync('prysm_controller_test_');
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async => tempDir.path);
}

Future<Database> _openMessagesDb() async {
  final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
  await MessageReadReceiptsDb.createTable(db);
  return db;
}

class _FakeReactionService extends ReactionService {
  _FakeReactionService(KeyManager keyManager)
      : super.direct(userId: 'me', keyManager: keyManager, peerId: 'peer-1');

  final calls = <MapEntry<String, String>>[];

  @override
  Future<void> toggleReaction({
    required String targetMessageId,
    required String emoji,
  }) async {
    calls.add(MapEntry(targetMessageId, emoji));
  }
}

class _FakeReadReceiptService extends ReadReceiptService {
  _FakeReadReceiptService(KeyManager keyManager)
      : super.direct(userId: 'me', keyManager: keyManager, peerId: 'peer-1');

  final sent = <ReadWaterlineMark>[];

  @override
  Future<void> sendWaterline(ReadWaterlineMark mark) async {
    sent.add(mark);
  }
}

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    _mockPathProvider();
  });

  late KeyManager keyManager;
  late _FakeReactionService reactionService;
  late _FakeReadReceiptService readReceiptService;
  late TypingIndicatorService typingService;
  late TypingStateTracker typingTracker;
  late List<Map<String, dynamic>> typingSent;
  late ScrollController scrollController;
  late bool mounted;

  setUp(() async {
    keyManager = KeyManager.fromIdentity(await IdentityKeyPair.generate());
    reactionService = _FakeReactionService(keyManager);
    readReceiptService = _FakeReadReceiptService(keyManager);
    typingSent = [];
    typingService = TypingIndicatorService.direct(
      userId: 'me',
      peerId: 'peer-1',
      sendOverride: (peer, payload) async {
        typingSent.add({'peer': peer, ...payload});
      },
    );
    typingTracker = TypingStateTracker();
    scrollController = ScrollController();
    mounted = true;
    MessageDraftStore.instance.clearAll();
  });

  tearDown(() {
    reactionService.dispose();
    typingService.dispose();
    typingTracker.dispose();
    scrollController.dispose();
    MessageDraftStore.instance.clearAll();
  });

  ChatScreenController buildController({
    String draftKey = 'dm:peer-1',
    PrysmChatMessageList? messages,
    Map<String, Message>? messageCache,
    String conversationKey = 'peer-1',
    bool Function(TypingIndicatorEvent)? matchesTypingEvent,
    bool Function() typingIndicatorsEnabled = _alwaysTrue,
    String Function(String)? typistDisplayName,
    Future<ReadWaterlineMark?> Function()? markInboundRead,
    VoidCallback? cancelForegroundNotification,
    bool Function() sendReadReceiptsEnabled = _alwaysTrue,
    String? readReceiptGroupId,
    int Function()? requiredReadCount,
    bool gateWaterlineSendOnMounted = false,
    VoidCallback? onNewlyRead,
    ChatBatchFetcher? fetchMessageBatch,
    ChatRowDecryptor? decryptForDisplay,
    void Function(int)? seedNewestTimestamp,
    void Function(String)? onToast,
    String Function(Uint8List)? fileMessageSource,
    void Function(String)? onLargeFileUploadStart,
    void Function(String)? onFileMessageRemoved,
    ChatTextDispatcher? dispatchText,
    ChatFileDispatcher? dispatchFile,
    ChatVoiceDispatcher? dispatchVoice,
  }) {
    return ChatScreenController(
      localUserId: 'me',
      draftKey: draftKey,
      listScrollController: scrollController,
      isMounted: () => mounted,
      messages: messages,
      messageCache: messageCache,
      typingTracker: typingTracker,
      typingService: typingService,
      conversationKey: conversationKey,
      matchesTypingEvent: matchesTypingEvent ?? (e) => e.senderId == 'peer-1',
      typingIndicatorsEnabled: typingIndicatorsEnabled,
      typistDisplayName: typistDisplayName ?? (id) => id,
      reactionService: reactionService,
      readReceiptService: readReceiptService,
      markInboundRead: markInboundRead ?? () async => null,
      cancelForegroundNotification: cancelForegroundNotification ?? () {},
      sendReadReceiptsEnabled: sendReadReceiptsEnabled,
      readReceiptGroupId: readReceiptGroupId,
      requiredReadCount: requiredReadCount ?? () => 1,
      gateWaterlineSendOnMounted: gateWaterlineSendOnMounted,
      onNewlyRead: onNewlyRead,
      fetchMessageBatch: fetchMessageBatch ?? ({beforeTimestamp, beforeId}) async => const [],
      decryptForDisplay: decryptForDisplay ?? (rows) async => const [],
      seedNewestTimestamp: seedNewestTimestamp ?? (_) {},
      onToast: onToast ?? (_) {},
      fileMessageSource: fileMessageSource ?? (bytes) => '',
      onLargeFileUploadStart: onLargeFileUploadStart,
      onFileMessageRemoved: onFileMessageRemoved,
      dispatchText: dispatchText ?? ({required text, required messageId, replyToId}) async {},
      dispatchFile: dispatchFile ??
          ({required bytes, required fileName, required type, required messageId, replyToId, required viewOnce}) async {},
      dispatchVoice: dispatchVoice ??
          ({required bytes, required durationMs, required messageId, replyToId, required cachePath}) async {},
    );
  }

  TextMessage textMessage(String id, {String authorId = 'peer-1', String text = 'hi'}) =>
      TextMessage(id: id, authorId: authorId, text: text, createdAt: DateTime.now());

  group('reply draft', () {
    test('setReplyToMessage persists under draftKey and notifies', () {
      final controller = buildController();
      var notifications = 0;
      controller.addListener(() => notifications++);
      final msg = textMessage('m1');

      controller.setReplyToMessage(msg);

      expect(controller.replyToMessage?.id, 'm1');
      expect(notifications, 1);
      expect(MessageDraftStore.instance.get('dm:peer-1').reply?.messageId, 'm1');
    });

    test('restoreReplyDraft finds the message in the list', () {
      final msg = textMessage('m1');
      MessageDraftStore.instance.setReply(
        'dm:peer-1',
        const ReplyPreviewData(
          messageId: 'm1',
          authorId: 'peer-1',
          label: 'hi',
          kind: ReplyPreviewKind.text,
        ),
      );
      final controller = buildController(messages: PrysmChatMessageList(messages: [msg]));

      controller.restoreReplyDraft();

      expect(controller.replyToMessage?.id, 'm1');
      expect(controller.replyDraft, isNull);
    });

    test('restoreReplyDraft falls back to the raw draft when the message is gone', () {
      MessageDraftStore.instance.setReply(
        'dm:peer-1',
        const ReplyPreviewData(
          messageId: 'missing',
          authorId: 'peer-1',
          label: 'hi',
          kind: ReplyPreviewKind.text,
        ),
      );
      final controller = buildController();

      controller.restoreReplyDraft();

      expect(controller.replyToMessage, isNull);
      expect(controller.replyDraft?.messageId, 'missing');
    });

    test('clearReplyState clears both local state and the store', () {
      final controller = buildController();
      controller.setReplyToMessage(textMessage('m1'));

      controller.clearReplyState();

      expect(controller.replyToMessage, isNull);
      expect(controller.replyDraft, isNull);
      expect(MessageDraftStore.instance.get('dm:peer-1').reply, isNull);
    });

    test('group draftKey is independent from dm', () {
      final dm = buildController(draftKey: 'dm:peer-1');
      final grp = buildController(draftKey: 'group:g1');
      dm.setReplyToMessage(textMessage('m1'));

      expect(MessageDraftStore.instance.get('dm:peer-1').reply, isNotNull);
      expect(MessageDraftStore.instance.get('group:g1').reply, isNull);
      grp.setReplyToMessage(textMessage('m2'));
      expect(MessageDraftStore.instance.get('group:g1').reply?.messageId, 'm2');
    });
  });

  group('scroll', () {
    test('setStickToBottomSilently mutates without notifying', () {
      final controller = buildController();
      var notifications = 0;
      controller.addListener(() => notifications++);

      controller.setStickToBottomSilently(false);

      expect(controller.stickToBottom, false);
      expect(notifications, 0);
    });
  });

  group('typing', () {
    test('onTypingEvent applies only events matching the injected predicate', () {
      final controller = buildController();
      final now = DateTime.now().millisecondsSinceEpoch;

      controller.onTypingEvent(
        TypingIndicatorEvent(senderId: 'stranger', groupId: null, peerId: null, typing: true, timestamp: now),
      );
      expect(typingTracker.activeTypists('peer-1'), isEmpty);

      controller.onTypingEvent(
        TypingIndicatorEvent(senderId: 'peer-1', groupId: null, peerId: null, typing: true, timestamp: now),
      );
      expect(typingTracker.activeTypists('peer-1'), ['peer-1']);
    });

    test('typingTypistNames respects the enabled flag and display-name mapping', () {
      final controller = buildController(
        typingIndicatorsEnabled: () => false,
        typistDisplayName: (id) => 'Display($id)',
      );
      typingTracker.applyEvent(
        conversationKey: 'peer-1',
        senderId: 'peer-1',
        typing: true,
        timestamp: DateTime.now().millisecondsSinceEpoch,
      );

      expect(controller.typingTypistNames(), isEmpty);
    });

    test('onComposerTypingChanged forwards to the injected service', () async {
      final controller = buildController();
      controller.onComposerTypingChanged(true);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(typingSent.any((f) => f['typing'] == true), isTrue);
    });
  });

  group('reactions', () {
    test('onReactionSelected delegates to the injected ReactionService', () async {
      final controller = buildController();
      await controller.onReactionSelected(textMessage('m1'), '👍');
      expect(reactionService.calls.map((e) => '${e.key}:${e.value}'), ['m1:👍']);
    });

    test('applyReactionUpdate patches the message and cache, notifies', () {
      final cache = <String, Message>{};
      final controller = buildController(
        messages: PrysmChatMessageList(messages: [textMessage('m1')]),
        messageCache: cache,
      );
      var notifications = 0;
      controller.addListener(() => notifications++);

      controller.applyReactionUpdate(
        const ReactionUpdate(targetMessageId: 'm1', reactions: {'👍': ['peer-1']}),
      );

      expect(controller.messages.messages.single.reactions, {'👍': ['peer-1']});
      expect(cache['m1']?.reactions, {'👍': ['peer-1']});
      expect(notifications, 1);
    });

    test('applyReactionUpdate is a silent no-op when unmounted', () {
      final controller = buildController(
        messages: PrysmChatMessageList(messages: [textMessage('m1')]),
      );
      mounted = false;
      var notifications = 0;
      controller.addListener(() => notifications++);

      controller.applyReactionUpdate(
        const ReactionUpdate(targetMessageId: 'm1', reactions: {'👍': ['peer-1']}),
      );

      expect(notifications, 0);
    });
  });

  group('read receipts', () {
    test('markInboundAsRead is a no-op when nothing was marked', () async {
      var cancelCalls = 0;
      final controller = buildController(
        markInboundRead: () async => null,
        cancelForegroundNotification: () => cancelCalls++,
      );

      await controller.markInboundAsRead();

      expect(cancelCalls, 0);
      expect(readReceiptService.sent, isEmpty);
    });

    test('markInboundAsRead cancels the notification and debounces the waterline send', () async {
      var cancelCalls = 0;
      const waterline = ReadWaterlineMark(latestMessageId: 'm1', readUpToTimestamp: 100);
      final controller = buildController(
        markInboundRead: () async => waterline,
        cancelForegroundNotification: () => cancelCalls++,
      );

      await controller.markInboundAsRead();
      expect(cancelCalls, 1);
      expect(readReceiptService.sent, isEmpty); // still debouncing

      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(readReceiptService.sent, [waterline]);
    });

    test('markInboundAsRead honors gateWaterlineSendOnMounted (dm-only guard)', () async {
      const waterline = ReadWaterlineMark(latestMessageId: 'm1', readUpToTimestamp: 100);
      final controller = buildController(
        markInboundRead: () async => waterline,
        gateWaterlineSendOnMounted: true,
      );

      await controller.markInboundAsRead();
      mounted = false;
      await Future<void>.delayed(const Duration(milliseconds: 150));

      expect(readReceiptService.sent, isEmpty);
    });

    test('applyReadReceiptUpdate ignores updates for a different conversation', () async {
      // readReceiptGroupId=null (dm) must skip a group update, matching
      // `if (update.groupId != null) return;` in the original DM code.
      final controller = buildController(readReceiptGroupId: null);
      var notifications = 0;
      controller.addListener(() => notifications++);

      await controller.applyReadReceiptUpdate(
        const ReadReceiptUpdate(
          targetMessageId: 'm1',
          groupId: 'some-group',
          allRead: true,
          readByMemberId: {},
        ),
      );

      expect(notifications, 0);
    });

    test('applyReadReceiptUpdate refreshes outbound status honoring requiredReadCount', () async {
      final db = await _openMessagesDb();
      MessagesDb.setDatabaseForTest(db);
      addTearDown(() async {
        await db.close();
        MessagesDb.setDatabaseForTest(null);
      });

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
      final controller = buildController(
        messages: PrysmChatMessageList(messages: [outbound]),
        readReceiptGroupId: 'g1',
        requiredReadCount: () => 2,
      );

      await controller.applyReadReceiptUpdate(
        const ReadReceiptUpdate(
          targetMessageId: 'out1',
          groupId: 'g1',
          allRead: false,
          readByMemberId: {},
        ),
      );
      expect(controller.messages.messages.single.seenAt, isNull);

      await MessageReadReceiptsDb.upsertReceipt(
        wireMessageId: 'out1',
        readerId: 'member-b',
        readAt: 5100,
        groupId: 'g1',
      );
      var newlyReadCalls = 0;
      final controller2 = buildController(
        messages: PrysmChatMessageList(messages: [outbound]),
        readReceiptGroupId: 'g1',
        requiredReadCount: () => 2,
        onNewlyRead: () => newlyReadCalls++,
      );
      await controller2.applyReadReceiptUpdate(
        const ReadReceiptUpdate(
          targetMessageId: 'out1',
          groupId: 'g1',
          allRead: true,
          readByMemberId: {},
        ),
      );
      expect(controller2.messages.messages.single.seenAt, isNotNull);
      expect(newlyReadCalls, 1);
    });
  });

  group('pagination', () {
    test('loadMoreMessages advances the cursor and signals hasMore=false on a short page', () async {
      final rows = List.generate(5, (i) => {'id': 'm$i', 'timestamp': 1000 + i});
      final controller = buildController(
        fetchMessageBatch: ({beforeTimestamp, beforeId}) async => rows,
        decryptForDisplay: (r) async => r.map((row) => textMessage(row['id'] as String)).toList(),
      );

      await controller.loadMoreMessages();

      expect(controller.hasMore, false);
      expect(controller.messages.messages.length, 5);
    });

    test('loadMoreMessages is a no-op re-entry guard while loading/exhausted', () async {
      var fetchCalls = 0;
      final controller = buildController(
        fetchMessageBatch: ({beforeTimestamp, beforeId}) async {
          fetchCalls++;
          return const [];
        },
      );

      await controller.loadMoreMessages(); // empty batch -> hasMore=false
      await controller.loadMoreMessages(); // guarded by !hasMore

      expect(fetchCalls, 1);
    });

    test('empty batch does not notify listeners', () async {
      final controller = buildController(
        fetchMessageBatch: ({beforeTimestamp, beforeId}) async => const [],
      );
      var notifications = 0;
      controller.addListener(() => notifications++);

      await controller.loadMoreMessages();

      expect(notifications, 0);
    });
  });

  group('multi-select', () {
    test('toggleMessageSelection adds then removes, notifying each time', () {
      final controller = buildController();
      var notifications = 0;
      controller.addListener(() => notifications++);

      controller.toggleMessageSelection('m1');
      expect(controller.selectedMessageIds, {'m1'});
      controller.toggleMessageSelection('m1');
      expect(controller.selectedMessageIds, isEmpty);
      expect(notifications, 2);
    });

    test('clearSelection empties the set', () {
      final controller = buildController();
      controller.selectMessage('m1');
      controller.selectMessage('m2');

      controller.clearSelection();

      expect(controller.selectedMessageIds, isEmpty);
    });
  });

  group('send pipeline', () {
    test('handleSendText inserts optimistically, clears reply, dispatches', () async {
      final controller = buildController();
      controller.setReplyToMessage(textMessage('replied-to'));
      Map<String, dynamic>? dispatched;
      final dispatchController = buildController(
        dispatchText: ({required text, required messageId, replyToId}) async {
          dispatched = {'text': text, 'messageId': messageId, 'replyToId': replyToId};
        },
      );
      dispatchController.setReplyToMessage(textMessage('replied-to'));

      await dispatchController.handleSendText('hello world');

      expect(dispatchController.messages.messages.single, isA<TextMessage>());
      expect((dispatchController.messages.messages.single as TextMessage).text, 'hello world');
      expect(dispatchController.replyToMessage, isNull);
      expect(MessageDraftStore.instance.get('dm:peer-1').reply, isNull);
      expect(dispatched?['text'], 'hello world');
      expect(dispatched?['replyToId'], 'replied-to');
    });

    test('rejectOversizedFile toasts and returns true above the limit', () {
      String? toasted;
      final controller = buildController(onToast: (msg) => toasted = msg);

      final rejected = controller.rejectOversizedFile(2000 * 1024 * 1024);

      expect(rejected, isTrue);
      expect(toasted, isNotNull);
    });

    test('sendFile inserts optimistically using the injected source builder', () async {
      Map<String, dynamic>? dispatched;
      final controller = buildController(
        fileMessageSource: (bytes) => 'source-for-${bytes.length}-bytes',
        dispatchFile: ({required bytes, required fileName, required type, required messageId, replyToId, required viewOnce}) async {
          dispatched = {'fileName': fileName, 'type': type, 'viewOnce': viewOnce};
        },
      );

      await controller.sendFile(Uint8List.fromList([1, 2, 3]), 'doc.pdf', 'file');

      final inserted = controller.messages.messages.single as FileMessage;
      expect(inserted.name, 'doc.pdf');
      expect(inserted.source, 'source-for-3-bytes');
      expect(dispatched?['fileName'], 'doc.pdf');
      expect(dispatched?['type'], 'file');
    });

    test('removeOptimisticFileMessage removes the message, cache entry, and selection', () {
      final cache = <String, Message>{'m1': textMessage('m1')};
      final controller = buildController(
        messages: PrysmChatMessageList(messages: [textMessage('m1')]),
        messageCache: cache,
      );
      controller.selectMessage('m1');
      var removedIds = <String>[];

      final withHook = buildController(
        messages: PrysmChatMessageList(messages: [textMessage('m1')]),
        messageCache: cache,
        onFileMessageRemoved: removedIds.add,
      );
      withHook.removeOptimisticFileMessage('m1');

      expect(withHook.messages.messages, isEmpty);
      expect(cache.containsKey('m1'), isFalse);
      expect(removedIds, ['m1']);
      // Sanity: the first controller's own selection state is untouched by
      // the second controller's call.
      expect(controller.selectedMessageIds, {'m1'});
    });

    test('sendVoice writes a cache file and dispatches with its path', () async {
      Map<String, dynamic>? dispatched;
      final controller = buildController(
        dispatchVoice: ({required bytes, required durationMs, required messageId, replyToId, required cachePath}) async {
          dispatched = {'durationMs': durationMs, 'cachePath': cachePath};
        },
      );

      await controller.sendVoice(Uint8List.fromList(List.filled(200, 1)), 4200);

      final inserted = controller.messages.messages.single as FileMessage;
      expect(inserted.name, 'voice_message.wav');
      expect(dispatched?['durationMs'], 4200);
      final cachePath = dispatched?['cachePath'] as String;
      expect(File(cachePath).existsSync(), isTrue);
    });

    test('sendVoice returns without side effects if unmounted before the awaits', () async {
      var dispatchCalled = false;
      final controller = buildController(
        dispatchVoice: ({required bytes, required durationMs, required messageId, replyToId, required cachePath}) async {
          dispatchCalled = true;
        },
      );
      mounted = false;

      await controller.sendVoice(Uint8List.fromList(List.filled(200, 1)), 4200);

      expect(controller.messages.messages, isEmpty);
      expect(dispatchCalled, isFalse);
    });

    test('sendVoice returns without mutating state if unmounted (disposed) during the awaits', () async {
      var dispatchCalled = false;
      final controller = buildController(
        dispatchVoice: ({required bytes, required durationMs, required messageId, replyToId, required cachePath}) async {
          dispatchCalled = true;
        },
      );
      var notified = false;
      controller.addListener(() => notified = true);

      // Simulate the screen being disposed while awaiting getTemporaryDirectory
      // (the first of the two awaits sendVoice performs before its
      // post-await mounted guard).
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      final tempDir = Directory.systemTemp.createTempSync('prysm_controller_test_unmount_');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
        mounted = false;
        return tempDir.path;
      });
      addTearDown(_mockPathProvider);

      await controller.sendVoice(Uint8List.fromList(List.filled(200, 1)), 4200);

      expect(controller.messages.messages, isEmpty);
      expect(dispatchCalled, isFalse);
      expect(notified, isFalse);
    });
  });

  group('resetConversation', () {
    test('replaces messages and clears pagination/reply/selection state', () {
      final controller = buildController(
        messages: PrysmChatMessageList(messages: [textMessage('m1')]),
      );
      controller.setReplyToMessage(textMessage('m1'));
      controller.selectMessage('m1');

      controller.resetConversation();

      expect(controller.messages.messages, isEmpty);
      expect(controller.replyToMessage, isNull);
      expect(controller.selectedMessageIds, isEmpty);
      expect(controller.hasMore, isTrue);
      expect(controller.loading, isFalse);
    });
  });

  group('self-chat wiring (Fase 6C: peer-only collaborators left null)', () {
    // self_chat_screen.dart has no peer: typing/reactions/read-receipts are
    // never wired (all left null), only pagination + the send pipeline are
    // shared with DM/group. These guard clauses (`if (x == null) return`)
    // are exercised here since buildController() above always wires the
    // peer-only collaborators.
    ChatScreenController buildSelfController({
      PrysmChatMessageList? messages,
      ChatBatchFetcher? fetchMessageBatch,
      ChatRowDecryptor? decryptForDisplay,
      ChatTextDispatcher? dispatchText,
      ChatFileDispatcher? dispatchFile,
      ChatVoiceDispatcher? dispatchVoice,
    }) {
      return ChatScreenController(
        localUserId: 'me',
        draftKey: 'self:me',
        listScrollController: scrollController,
        isMounted: () => mounted,
        messages: messages,
        fetchMessageBatch:
            fetchMessageBatch ?? ({beforeTimestamp, beforeId}) async => const [],
        decryptForDisplay: decryptForDisplay ?? (rows) async => const [],
        seedNewestTimestamp: (_) {},
        onToast: (_) {},
        fileMessageSource: (bytes) => 'self-source',
        dispatchText: dispatchText ?? ({required text, required messageId, replyToId}) async {},
        dispatchFile: dispatchFile ??
            ({required bytes, required fileName, required type, required messageId, replyToId, required viewOnce}) async {},
        dispatchVoice: dispatchVoice ??
            ({required bytes, required durationMs, required messageId, replyToId, required cachePath}) async {},
      );
    }

    test('onTypingEvent is a silent no-op with no typing collaborators wired', () {
      final controller = buildSelfController();
      controller.onTypingEvent(
        const TypingIndicatorEvent(
          senderId: 'me',
          groupId: null,
          peerId: null,
          typing: true,
          timestamp: 0,
        ),
      );
      expect(controller.typingTypistNames(), isEmpty);
    });

    test('typingTypistNames returns empty with no typing collaborators wired', () {
      expect(buildSelfController().typingTypistNames(), isEmpty);
    });

    test('onComposerTypingChanged is a silent no-op with no typing service wired', () {
      expect(() => buildSelfController().onComposerTypingChanged(true), returnsNormally);
    });

    test('onReactionSelected is a silent no-op with no reaction service wired', () async {
      final controller = buildSelfController();
      // reactionService == null short-circuits before any dispatch; a lack
      // of exception is the assertion.
      await controller.onReactionSelected(textMessage('m1'), '👍');
    });

    test('markInboundAsRead is a silent no-op with no read-receipt collaborators wired', () async {
      final controller = buildSelfController();
      // markInboundRead/sendReadReceiptsEnabled/readReceiptService are all
      // null; the guard clause returns before touching any of them.
      await controller.markInboundAsRead();
    });

    test('applyReadReceiptUpdate is a silent no-op with no read-receipt collaborators wired', () async {
      final controller = buildSelfController(
        messages: PrysmChatMessageList(messages: [textMessage('m1', authorId: 'me')]),
      );
      await controller.applyReadReceiptUpdate(
        const ReadReceiptUpdate(
          targetMessageId: 'm1',
          allRead: true,
          readByMemberId: {},
        ),
      );
      expect(controller.messages.messages.single.seenAt, isNull);
    });

    test('pagination and send pipeline work end-to-end with peer-only collaborators null', () async {
      final rows = [
        {'id': 'm1', 'timestamp': 1000},
      ];
      Map<String, dynamic>? dispatched;
      final controller = buildSelfController(
        fetchMessageBatch: ({beforeTimestamp, beforeId}) async => rows,
        decryptForDisplay: (rows) async =>
            rows.map((r) => textMessage(r['id'] as String)).toList(),
        dispatchText: ({required text, required messageId, replyToId}) async {
          dispatched = {'text': text, 'messageId': messageId};
        },
      );

      await controller.loadMoreMessages();
      expect(controller.messages.messages, hasLength(1));
      expect(controller.hasMore, isFalse);

      await controller.handleSendText('hello myself');
      expect(controller.messages.messages, hasLength(2));
      expect(dispatched?['text'], 'hello myself');
    });
  });
}

bool _alwaysTrue() => true;
