// Fase 6B: single, parametrized orchestration controller shared by the
// direct-chat and group-chat screens. Fase 6C wires the self-chat screen
// too: typing, reactions and read receipts (peer-only concepts) became
// optional constructor collaborators — `null` for self — while pagination,
// stick-to-bottom scroll and the optimistic-insert send pipeline are shared
// verbatim. MessageViewMapper / MessageActionsService stay DM/group-only
// (self decrypts via SelfChatService and has no edit/modify pipeline).
//
// Owns the areas that used to be duplicated almost line-for-line between
// `_ChatScreenState` and `_GroupChatScreenState`: reply draft, scroll
// scheduling, typing, reactions, read receipts, pagination, multi-select and
// the send pipeline's optimistic-insert mechanics. The controller never
// touches `BuildContext` or returns `Widget`s — it exposes state (via
// `ChangeNotifier`) and imperative methods; the `State`s bind to it (add a
// listener that calls `setState(() {})`) and keep every widget-facing
// concern (toasts, navigation, dialogs) themselves.
//
// Where DM and group genuinely diverge in *observable* behaviour (which DAO
// call to make, whether a send is awaited or fire-and-forget, whether
// `reloadConversations()` fires, the toast copy, whether a message cache
// exists) the divergence is preserved via constructor-injected callbacks —
// the same "optional knob" idiom `MessageActionsService` used in Fase 6A
// (`groupId`, `cancelPendingSend`) — rather than silently unified.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:prysm/models/chat/prysm_message.dart';
import 'package:prysm/models/reply_preview_data.dart';
import 'package:prysm/screens/widgets/message_reaction_bar.dart'
    show applyReactionsToMessage;
import 'package:prysm/services/image_attachment_cache.dart';
import 'package:prysm/services/message_draft_store.dart';
import 'package:prysm/services/reaction_service.dart';
import 'package:prysm/services/read_receipt_service.dart';
import 'package:prysm/services/typing_indicator_service.dart';
import 'package:prysm/services/typing_state_tracker.dart';
import 'package:prysm/ui/chat/prysm_chat_message_list.dart';
import 'package:prysm/util/chat_scroll.dart';
import 'package:prysm/util/file_transfer_policy.dart';
import 'package:prysm/util/message_status_mapper.dart';
import 'package:prysm/util/outbound_read_status_refresh.dart';
import 'package:prysm/util/read_waterline_mark.dart';
import 'package:prysm/util/reply_preview_label.dart';
import 'package:prysm/util/typing_indicator_notifier.dart';
import 'package:prysm/util/waveform_extractor.dart';
import 'package:uuid/uuid.dart';

/// DAO batch fetch for one page of history, older than the given cursor.
typedef ChatBatchFetcher = Future<List<Map<String, dynamic>>> Function({
  int? beforeTimestamp,
  String? beforeId,
});

/// Row -> [Message] decrypt/mapping pipeline (DM: `MessageViewMapper`,
/// group: the still-inline `_decryptBatch`/sender-key pipeline — Fase 6A
/// deliberately left that one alone, see fase6a-report.md).
typedef ChatRowDecryptor = Future<List<Message>> Function(
  List<Map<String, dynamic>> rows,
);

/// Sends a text message (covers both the `detachedClient` and
/// `ChatService`/`GroupChatService` branches, plus whatever toast/reload
/// side effect the screen wants on failure/success — fully screen-owned
/// because DM fires-and-forgets while group awaits + always reloads).
typedef ChatTextDispatcher = Future<void> Function({
  required String text,
  required String messageId,
  String? replyToId,
});

/// Sends a file/image (already optimistically inserted). Screen-owned for
/// the same reason as [ChatTextDispatcher]: DM shares one outcome path for
/// both transports, group has three different outcomes (detached-failure,
/// service-success, service-failure) — see fase6b-report.md.
typedef ChatFileDispatcher = Future<void> Function({
  required Uint8List bytes,
  required String fileName,
  required String type,
  required String messageId,
  String? replyToId,
  required bool viewOnce,
});

/// Sends a voice message (already optimistically inserted, cache file
/// already written).
typedef ChatVoiceDispatcher = Future<void> Function({
  required Uint8List bytes,
  required int durationMs,
  required String messageId,
  String? replyToId,
  required String cachePath,
});

/// Shared orchestration for a DM or group chat screen. See file header.
class ChatScreenController extends ChangeNotifier {
  ChatScreenController({
    required this.localUserId,
    required this.draftKey,
    required this.listScrollController,
    required this.isMounted,
    PrysmChatMessageList? messages,
    this.messageCache,
    // Typing (peer-only; `null` for self-chat).
    this.typingTracker,
    this.typingService,
    this.conversationKey,
    this.matchesTypingEvent,
    this.typingIndicatorsEnabled,
    this.typistDisplayName,
    // Reactions (peer-only; `null` for self-chat).
    this.reactionService,
    // Read receipts (peer-only; `null` for self-chat).
    this.readReceiptService,
    this.markInboundRead,
    this.cancelForegroundNotification,
    this.sendReadReceiptsEnabled,
    this.readReceiptGroupId,
    this.requiredReadCount,
    this.gateWaterlineSendOnMounted = false,
    this.onNewlyRead,
    // Pagination.
    required this.fetchMessageBatch,
    required this.decryptForDisplay,
    required this.seedNewestTimestamp,
    // Send pipeline.
    required this.onToast,
    this.fileMessageSource = _emptyFileSource,
    this.onLargeFileUploadStart,
    this.onFileMessageRemoved,
    required this.dispatchText,
    required this.dispatchFile,
    required this.dispatchVoice,
    this.voiceCacheFileNamePrefix = 'voice_cache',
  }) : messages = messages ?? PrysmChatMessageList();

  static String _emptyFileSource(Uint8List bytes) => '';

  // ---- Identity / shared collaborators ------------------------------
  final String localUserId;
  final String draftKey;
  final ScrollController listScrollController;
  final bool Function() isMounted;
  PrysmChatMessageList messages;

  /// DM caches decrypted messages by id for O(1) reaction/read-receipt
  /// patch-ups; group never built one (fase6a report). Left `null` for
  /// group so `applyReactionUpdate`/`applyReadReceiptUpdate` skip it.
  final Map<String, Message>? messageCache;

  // ---- Typing (peer-only; all `null` for self-chat) -------------------
  final TypingStateTracker? typingTracker;
  final TypingIndicatorService? typingService;
  final String? conversationKey;
  final bool Function(TypingIndicatorEvent event)? matchesTypingEvent;
  final bool Function()? typingIndicatorsEnabled;
  final String Function(String senderId)? typistDisplayName;

  // ---- Reactions (peer-only; `null` for self-chat) ----------------------
  final ReactionService? reactionService;

  // ---- Read receipts (peer-only; all `null` for self-chat) ------------
  final ReadReceiptService? readReceiptService;
  final Future<ReadWaterlineMark?> Function()? markInboundRead;
  final VoidCallback? cancelForegroundNotification;
  final bool Function()? sendReadReceiptsEnabled;

  /// `null` for DM, `widget.group.id` for group — also doubles as the
  /// exact filter rule from the original code: DM only applied updates
  /// with `update.groupId == null`, group only those matching its own id.
  final String? readReceiptGroupId;
  final int Function()? requiredReadCount;

  /// DM's debounced waterline send re-checks `mounted` before firing;
  /// group's never did. Preserved exactly rather than silently unified,
  /// since it changes whether a receipt is actually sent over the wire.
  final bool gateWaterlineSendOnMounted;

  /// DM calls `_recordPeerActivity()` when a message newly becomes read;
  /// group has no peer-presence concept.
  final VoidCallback? onNewlyRead;
  Timer? _readReceiptDebounce;

  // ---- Pagination -----------------------------------------------------
  static const _pageSize = 20;
  final ChatBatchFetcher fetchMessageBatch;
  final ChatRowDecryptor decryptForDisplay;
  final void Function(int newestTimestamp) seedNewestTimestamp;
  bool _loading = false;
  bool _hasMore = true;
  int? _oldestTimestamp;
  String? _oldestMessageId;
  bool get loading => _loading;
  bool get hasMore => _hasMore;

  // ---- Multi-select -----------------------------------------------------
  final Set<String> selectedMessageIds = {};

  // ---- Reply draft --------------------------------------------------
  Message? _replyToMessage;
  ReplyPreviewData? _replyDraft;
  Message? get replyToMessage => _replyToMessage;
  ReplyPreviewData? get replyDraft => _replyDraft;
  String? get replyToMessageId => _replyToMessage?.id ?? _replyDraft?.messageId;

  // ---- Scroll -----------------------------------------------------------
  bool _stickToBottom = true;
  bool get stickToBottom => _stickToBottom;

  // ---- Send pipeline ------------------------------------------------
  final void Function(String message) onToast;
  final String Function(Uint8List bytes) fileMessageSource;
  final void Function(String messageId)? onLargeFileUploadStart;
  final void Function(String messageId)? onFileMessageRemoved;
  final ChatTextDispatcher dispatchText;
  final ChatFileDispatcher dispatchFile;
  final ChatVoiceDispatcher dispatchVoice;
  final String voiceCacheFileNamePrefix;

  @override
  void dispose() {
    _readReceiptDebounce?.cancel();
    super.dispose();
  }

  // ======================================================================
  // Reply draft — identical between DM/group except `draftKey`
  // ('dm:$peerId' vs 'group:${group.id}'), computed by the caller.
  // ======================================================================

  void persistReplyDraft() {
    final data = _replyToMessage != null
        ? replyPreviewFromMessage(_replyToMessage!)
        : _replyDraft;
    MessageDraftStore.instance.setReply(draftKey, data);
  }

  void restoreReplyDraft() {
    final stored = MessageDraftStore.instance.get(draftKey).reply;
    if (stored == null) return;
    Message? found;
    for (final message in messages.messages) {
      if (message.id == stored.messageId) {
        found = message;
        break;
      }
    }
    _replyToMessage = found;
    _replyDraft = found == null ? stored : null;
    notifyListeners();
  }

  void clearReplyState() {
    _replyToMessage = null;
    _replyDraft = null;
    MessageDraftStore.instance.setReply(draftKey, null);
    notifyListeners();
  }

  void setReplyToMessage(Message message) {
    _replyToMessage = message;
    _replyDraft = null;
    notifyListeners();
    persistReplyDraft();
  }

  // ======================================================================
  // Scroll — byte-identical logic in both screens.
  // ======================================================================

  void onListScroll() {
    final atBottom = isChatScrolledToBottom(listScrollController);
    if (atBottom == _stickToBottom) return;
    _stickToBottom = atBottom;
    notifyListeners();
  }

  /// Mirrors the original `onStickToBottomChanged: (atBottom) { _stickToBottom
  /// = atBottom; }` viewport callback, which mutated the field directly
  /// without `setState` — deliberately does not notify listeners.
  void setStickToBottomSilently(bool value) {
    _stickToBottom = value;
  }

  void scheduleScrollToBottomIfNeeded({bool animated = false}) {
    if (!_stickToBottom) return;
    scheduleScrollChatToBottom(messages, animated: animated, isMounted: isMounted);
  }

  void scheduleScrollToBottomAfterSend() {
    _stickToBottom = true;
    scheduleScrollChatToBottom(messages, isMounted: isMounted);
  }

  // ======================================================================
  // Typing.
  // ======================================================================

  void onTypingEvent(TypingIndicatorEvent event) {
    final tracker = typingTracker;
    final matches = matchesTypingEvent;
    final key = conversationKey;
    if (tracker == null || matches == null || key == null) return;
    if (!matches(event)) return;
    tracker.applyEvent(
      conversationKey: key,
      senderId: event.senderId,
      typing: event.typing,
      timestamp: event.timestamp,
    );
  }

  List<String> typingTypistNames() {
    final tracker = typingTracker;
    final enabled = typingIndicatorsEnabled;
    final nameOf = typistDisplayName;
    final key = conversationKey;
    if (tracker == null || enabled == null || nameOf == null || key == null) {
      return const [];
    }
    if (!enabled()) return const [];
    return tracker
        .activeTypists(key)
        .map(nameOf)
        .toList(growable: false);
  }

  void onComposerTypingChanged(bool isTyping) {
    typingService?.onComposerTypingChanged(isTyping);
  }

  // ======================================================================
  // Reactions.
  // ======================================================================

  Future<void> onReactionSelected(Message message, String emoji) async {
    final service = reactionService;
    if (service == null) return;
    await service.toggleReaction(
      targetMessageId: message.id,
      emoji: emoji,
    );
  }

  void applyReactionUpdate(ReactionUpdate update) {
    if (!isMounted()) return;
    try {
      final msg = messages.messages.firstWhere((m) => m.id == update.targetMessageId);
      final updated = applyReactionsToMessage(msg, update.reactions);
      messages.updateMessage(msg, updated);
      messageCache?[msg.id] = updated;
      notifyListeners();
    } catch (_) {}
  }

  // ======================================================================
  // Read receipts.
  // ======================================================================

  Future<void> markInboundAsRead() async {
    final markRead = markInboundRead;
    final receiptsEnabled = sendReadReceiptsEnabled;
    final receipts = readReceiptService;
    if (markRead == null || receiptsEnabled == null || receipts == null) {
      return;
    }
    final waterline = await markRead();
    if (waterline == null) return;

    cancelForegroundNotification?.call();

    _readReceiptDebounce?.cancel();
    _readReceiptDebounce = Timer(const Duration(milliseconds: 100), () async {
      if (gateWaterlineSendOnMounted && !isMounted()) return;
      if (receiptsEnabled()) {
        await receipts.sendWaterline(waterline);
      }
    });
  }

  Future<void> applyReadReceiptUpdate(ReadReceiptUpdate update) async {
    final receiptsEnabled = sendReadReceiptsEnabled;
    final readCount = requiredReadCount;
    if (receiptsEnabled == null || readCount == null) return;
    if (!isMounted() || !receiptsEnabled()) return;
    if (update.groupId != readReceiptGroupId) return;

    final refreshed = await refreshOutboundReadStatus(
      messages: messages.messages,
      localUserId: localUserId,
      readReceiptsEnabled: receiptsEnabled(),
      groupId: readReceiptGroupId,
      requiredReadCount: readCount(),
    );
    if (!isMounted()) return;

    var anyNewlyRead = false;
    for (final updated in refreshed) {
      if (updated.authorId != localUserId) continue;
      try {
        final old = messages.messages.firstWhere((m) => m.id == updated.id);
        if (old.seenAt == updated.seenAt &&
            old.metadata?['deliveryStatus'] == updated.metadata?['deliveryStatus']) {
          continue;
        }
        if (updated.seenAt != null && old.seenAt == null) {
          anyNewlyRead = true;
        }
        messages.updateMessage(old, updated);
        messageCache?[updated.id] = updated;
      } catch (_) {}
    }
    notifyListeners();

    if (anyNewlyRead) onNewlyRead?.call();
  }

  // ======================================================================
  // Pagination.
  // ======================================================================

  Future<void> loadMoreMessages() async {
    if (_loading || !_hasMore) return;
    _loading = true;

    final batch = await fetchMessageBatch(
      beforeTimestamp: _oldestTimestamp,
      beforeId: _oldestMessageId,
    );
    if (!isMounted()) return;

    if (batch.length < _pageSize) _hasMore = false;
    if (batch.isEmpty) {
      _loading = false;
      return;
    }

    final sorted = List<Map<String, dynamic>>.from(batch)
      ..sort((a, b) => (a['timestamp'] as int).compareTo(b['timestamp'] as int));

    final newestTs = sorted.map((m) => m['timestamp'] as int).reduce((a, b) => a > b ? a : b);
    seedNewestTimestamp(newestTs);

    final decrypted = await decryptForDisplay(sorted);
    if (!isMounted()) {
      _loading = false;
      return;
    }

    messages.insertAllMessages(decrypted, index: 0);
    _oldestTimestamp = batch.last['timestamp'] as int;
    _oldestMessageId = batch.last['id'] as String;
    _loading = false;
    notifyListeners();
  }

  // ======================================================================
  // Multi-select.
  // ======================================================================

  void selectMessage(String id) {
    selectedMessageIds.add(id);
    notifyListeners();
  }

  void toggleMessageSelection(String id) {
    if (!selectedMessageIds.remove(id)) selectedMessageIds.add(id);
    notifyListeners();
  }

  void clearSelection() {
    selectedMessageIds.clear();
    notifyListeners();
  }

  // ======================================================================
  // Conversation reset (delete chat / delete contact — DM only today).
  // Consolidates what used to be `resetChatState()` followed immediately by
  // a redundant second `_messages = InMemoryChatController()` inside
  // `setState` at each of chat.dart's two call sites: both reassignments
  // produced the same empty list, so folding them into one is behaviourally
  // identical, just without the pointless double-allocation.
  // ======================================================================

  void resetConversation() {
    messages = PrysmChatMessageList();
    _replyToMessage = null;
    _replyDraft = null;
    messageCache?.clear();
    _oldestTimestamp = null;
    _oldestMessageId = null;
    _hasMore = true;
    _loading = false;
    selectedMessageIds.clear();
    notifyListeners();
  }

  // ======================================================================
  // Send pipeline — shared optimistic-insert mechanics; the actual network
  // dispatch (and its outcome: toast copy, reload, cache cleanup) is
  // screen-owned via the injected `dispatch*` callbacks, since DM and group
  // genuinely differ there (await vs fire-and-forget, reload-on-success,
  // distinct failure toasts) — see fase6b-report.md.
  // ======================================================================

  bool rejectOversizedFile(int byteLength) {
    if (FileTransferPolicy.isWithinMaxFileSize(byteLength)) return false;
    onToast(FileTransferPolicy.maxFileSizeError);
    return true;
  }

  void removeOptimisticFileMessage(String messageId) {
    final idx = messages.messages.indexWhere((m) => m.id == messageId);
    if (idx != -1) {
      messages.removeMessage(messages.messages[idx]);
      selectedMessageIds.remove(messageId);
    }
    messageCache?.remove(messageId);
    notifyListeners();
    onFileMessageRemoved?.call(messageId);
  }

  Future<void> handleSendText(String text) async {
    final replyToId = replyToMessageId;
    final messageId = const Uuid().v4();

    messages.insertMessage(
      messageWithPendingStatus(
        TextMessage(
          authorId: localUserId,
          createdAt: DateTime.now(),
          id: messageId,
          text: text,
          replyToMessageId: replyToId,
        ),
      ),
      index: messages.messages.length,
    );
    _replyToMessage = null;
    _replyDraft = null;
    notifyListeners();
    MessageDraftStore.instance.setReply(draftKey, null);
    scheduleScrollToBottomAfterSend();

    await dispatchText(text: text, messageId: messageId, replyToId: replyToId);
  }

  Future<void> sendFile(
    Uint8List bytes,
    String fileName,
    String type, {
    bool viewOnce = false,
  }) async {
    if (rejectOversizedFile(bytes.length)) return;

    final messageId = const Uuid().v4();
    final replyToId = replyToMessageId;

    if (type == 'file') {
      if (bytes.length >= FileTransferPolicy.chunkThresholdBytes) {
        onLargeFileUploadStart?.call(messageId);
      }
      messages.insertMessage(
        messageWithPendingStatus(
          FileMessage(
            authorId: localUserId,
            createdAt: DateTime.now(),
            id: messageId,
            name: fileName,
            size: bytes.length,
            replyToMessageId: replyToId,
            source: fileMessageSource(bytes),
          ),
        ),
        index: messages.messages.length,
      );
    } else if (type == 'image') {
      messages.insertMessage(
        messageWithPendingStatus(
          ImageMessage(
            authorId: localUserId,
            createdAt: DateTime.now(),
            id: messageId,
            size: bytes.length,
            replyToMessageId: replyToId,
            source:
                'data:${ImageAttachmentCache.sniffImageMimeType(bytes)};base64,${base64Encode(bytes)}',
            metadata: viewOnce ? {'viewOnce': true, 'viewed': false} : null,
          ),
        ),
        index: messages.messages.length,
      );
    }
    _replyToMessage = null;
    _replyDraft = null;
    notifyListeners();
    MessageDraftStore.instance.setReply(draftKey, null);
    scheduleScrollToBottomAfterSend();

    await dispatchFile(
      bytes: bytes,
      fileName: fileName,
      type: type,
      messageId: messageId,
      replyToId: replyToId,
      viewOnce: viewOnce,
    );
  }

  Future<void> sendVoice(Uint8List bytes, int durationMs) async {
    if (!isMounted()) return;

    final messageId = const Uuid().v4();
    final replyToId = replyToMessageId;

    final cacheDir = await getTemporaryDirectory();
    final cachePath = '${cacheDir.path}/${voiceCacheFileNamePrefix}_$messageId.wav';
    await File(cachePath).writeAsBytes(bytes);

    if (!isMounted()) return;

    final peaks = WaveformExtractor.extractPeaks(bytes);
    final waveformMeta = WaveformExtractor.encodePeaks(peaks);

    messages.insertMessage(
      messageWithPendingStatus(
        FileMessage(
          authorId: localUserId,
          createdAt: DateTime.now(),
          id: messageId,
          replyToMessageId: replyToId,
          name: 'voice_message.wav',
          size: bytes.length,
          source: 'audio:$durationMs:$cachePath',
          metadata: {'waveform': waveformMeta},
        ),
      ),
      index: messages.messages.length,
    );
    _replyToMessage = null;
    _replyDraft = null;
    notifyListeners();
    MessageDraftStore.instance.setReply(draftKey, null);
    scheduleScrollToBottomAfterSend();

    await dispatchVoice(
      bytes: bytes,
      durationMs: durationMs,
      messageId: messageId,
      replyToId: replyToId,
      cachePath: cachePath,
    );
  }

}
