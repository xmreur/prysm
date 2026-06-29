import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:prysm/constants/group_constants.dart';
import 'package:prysm/database/messages.dart';
import 'package:prysm/services/group_service.dart';
import 'package:prysm/util/group_crypto.dart';
import 'package:prysm/util/battery_saver_policy.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/tor_delivery.dart';
import 'package:prysm/transport/transport_provider.dart';
import 'package:prysm/util/tor_runtime_gate.dart';
import 'package:prysm/util/pending_message_db_helper.dart';
import 'package:prysm/util/inbound_message_notifier.dart';
import 'package:prysm/util/group_sender_index_store.dart';
import 'package:uuid/uuid.dart';

class GroupChatService {
  final String userId;
  final String groupId;
  final KeyManager keyManager;
  final GroupService groupService;

  Uint8List? _groupKey;
  List<String> _memberIds = [];

  bool _isPolling = false;
  bool _isSending = false;
  bool _disposed = false;
  int _pollIntervalSeconds = BatterySaverPolicy.chatPollActiveSeconds(false);
  int _consecutivePollErrors = 0;
  int? _newestTimestamp;
  final Set<String> _seenMessageIds = {};
  StreamSubscription<InboundMessageEvent>? _inboundSub;

  final _newMessagesController =
      StreamController<List<Map<String, dynamic>>>.broadcast();
  final _messageStatusController =
      StreamController<GroupMessageStatusUpdate>.broadcast();

  Stream<List<Map<String, dynamic>>> get onNewMessages =>
      _newMessagesController.stream;
  Stream<GroupMessageStatusUpdate> get onMessageStatus =>
      _messageStatusController.stream;

  GroupChatService({
    required this.userId,
    required this.groupId,
    required this.keyManager,
    required this.groupService,
  });

  void dispose() {
    _disposed = true;
    _isPolling = false;
    _isSending = false;
    _inboundSub?.cancel();
    _inboundSub = null;
    _newMessagesController.close();
    _messageStatusController.close();
  }

  Future<bool> initialize() async {
    await _refreshSession();
    return _groupKey != null && _memberIds.isNotEmpty;
  }

  Future<void> _refreshSession() async {
    if (!await groupService.isMember(groupId)) {
      _groupKey = null;
      _memberIds = [];
      return;
    }
    _groupKey = await groupService.getDecryptedGroupKey(groupId);
    final members = await groupService.getMembers(groupId);
    _memberIds = members.map((m) => m.memberId).toList();
  }

  void startPolling() {
    if (_isPolling) return;
    _isPolling = true;
    _subscribeInbound();
    _loopPoll();
  }

  void _subscribeInbound() {
    _inboundSub ??= InboundMessageNotifier.instance.onInboundMessage.listen(
      _onInboundMessage,
    );
  }

  void _onInboundMessage(InboundMessageEvent event) {
    if (_disposed) return;
    if (event.groupId != groupId) return;
    _deliverNewRows([event.row]);
  }

  void stopPolling() {
    _isPolling = false;
  }

  void pinMembersForWebSocket() {
    if (!TransportProvider.isConfigured) return;
    final transport = TransportProvider.instance;
    for (final member in _memberIds) {
      if (member == userId) continue;
      transport.pinPeer(member);
    }
  }

  void unpinMembersForWebSocket() {
    if (!TransportProvider.isConfigured) return;
    final transport = TransportProvider.instance;
    for (final member in _memberIds) {
      if (member == userId) continue;
      transport.unpinPeer(member);
    }
  }

  void startSendQueue() {
    _processSendQueue();
  }

  /// Avoid re-processing historical messages on the first poll after chat open.
  void seedNewestTimestamp(int timestamp) {
    if (_newestTimestamp == null || timestamp > _newestTimestamp!) {
      _newestTimestamp = timestamp;
    }
  }

  Future<String?> sendTextMessage(
    String text, {
    String? replyToId,
    String? messageId,
  }) async {
    await _refreshSession();
    if (_groupKey == null) return null;

    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final id = messageId ?? const Uuid().v4();
    final index = await GroupSenderIndexStore.nextIndex(
      groupId: groupId,
      senderId: userId,
    );
    final encrypted = await GroupCrypto.encryptWithSenderKey(
      epochKey: _groupKey!,
      senderId: userId,
      messageIndex: index,
      plaintext: text,
    );

    await MessagesDb.insertMessage({
      'id': id,
      'senderId': userId,
      'receiverId': userId,
      'groupId': groupId,
      'message': encrypted,
      'type': groupTextType,
      'status': 'pending',
      'timestamp': timestamp,
      'replyTo': replyToId,
    });

    final targets = _memberIds.where((m) => m != userId).toList();
    var successCount = 0;

    for (final target in targets) {
      final success = await _sendOverTor(
        id: id,
        targetMemberId: target,
        encrypted: encrypted,
        type: groupTextType,
        replyToId: replyToId,
        timestamp: timestamp,
      );
      if (success) {
        successCount++;
      } else {
        await _addToPendingQueue(
          messageId: id,
          targetMemberId: target,
          encrypted: encrypted,
          type: groupTextType,
          replyToId: replyToId,
          timestamp: timestamp,
        );
      }
    }

    await _finalizeSendOutcome(id, targets.length, successCount);
    return id;
  }

  String _groupTypeForMedia(String type) {
    switch (type) {
      case 'image':
        return groupImageType;
      case 'audio':
        return groupAudioType;
      case 'file':
      default:
        return groupFileType;
    }
  }

  Future<String?> sendFileMessage(
    Uint8List bytes,
    String fileName,
    String type, {
    String? replyToId,
    String? messageId,
    bool viewOnce = false,
  }) async {
    await _refreshSession();
    if (_groupKey == null) return null;

    final groupType = _groupTypeForMedia(type);
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final id = messageId ?? const Uuid().v4();
    final encrypted = await GroupCrypto.encryptGroupFile(_groupKey!, bytes);

    await MessagesDb.insertMessage({
      'id': id,
      'senderId': userId,
      'receiverId': userId,
      'groupId': groupId,
      'message': encrypted,
      'type': groupType,
      'fileName': fileName,
      'fileSize': bytes.length,
      'timestamp': timestamp,
      'replyTo': replyToId,
      'status': 'pending',
      'viewOnce': viewOnce ? 1 : 0,
    });

    final targets = _memberIds.where((m) => m != userId).toList();
    var successCount = 0;

    for (final target in targets) {
      final success = await _sendOverTor(
        id: id,
        targetMemberId: target,
        encrypted: encrypted,
        type: groupType,
        replyToId: replyToId,
        timestamp: timestamp,
        fileName: fileName,
        fileSize: bytes.length,
        viewOnce: viewOnce,
      );
      if (success) {
        successCount++;
      } else {
        await _addToPendingQueue(
          messageId: id,
          targetMemberId: target,
          encrypted: encrypted,
          type: groupType,
          replyToId: replyToId,
          timestamp: timestamp,
          fileName: fileName,
          fileSize: bytes.length,
          viewOnce: viewOnce,
        );
      }
    }

    await _finalizeSendOutcome(id, targets.length, successCount);
    return id;
  }

  Future<void> _loopPoll() async {
    while (_isPolling && !_disposed) {
      try {
        final hadNew = await _fetchNewMessages();
        _consecutivePollErrors = 0;
        _pollIntervalSeconds = _effectivePollIntervalSeconds(hadNew);
      } catch (e) {
        print('Group polling error: $e');
        _consecutivePollErrors++;
        final base = BatterySaverPolicy.chatPollActiveSeconds();
        _pollIntervalSeconds = min(30, base * (1 << _consecutivePollErrors));
      }

      if (_isPolling && !_disposed) {
        await Future.delayed(Duration(seconds: _pollIntervalSeconds));
      }
    }
  }

  int _effectivePollIntervalSeconds(bool hadNew) {
    if (_anyMemberRealtimeConnected) {
      return BatterySaverPolicy.wsSafetyPollSeconds;
    }
    return hadNew
        ? BatterySaverPolicy.chatPollActiveSeconds()
        : BatterySaverPolicy.chatPollIdleSeconds();
  }

  bool get _anyMemberRealtimeConnected {
    if (!TransportProvider.isConfigured) return false;
    final transport = TransportProvider.instance;
    return _memberIds.any(
      (member) => member != userId && transport.isRealtimeConnected(member),
    );
  }

  Future<bool> _fetchNewMessages() async {
    await _refreshSession();
    final joinedAt = await groupService.joinedAtForCurrentUser(groupId);
    final batch = await MessagesDb.getMessagesForGroupBatch(
      groupId,
      limit: 20,
      afterTimestamp: joinedAt,
    );
    if (batch.isEmpty) return false;
    return _deliverNewRows(batch);
  }

  bool _deliverNewRows(List<Map<String, dynamic>> rows) {
    if (_disposed) return false;

    final newMessages = rows.where((msg) {
      final msgId = msg['id'] as String;
      if (_seenMessageIds.contains(msgId)) return false;
      if (_newestTimestamp != null &&
          (msg['timestamp'] as int) <= _newestTimestamp!) {
        return false;
      }
      return true;
    }).toList();

    if (newMessages.isEmpty) return false;

    for (final msg in newMessages) {
      _seenMessageIds.add(msg['id'] as String);
    }

    _newestTimestamp = newMessages
        .map((m) => m['timestamp'] as int)
        .reduce(max);

    if (!_disposed) {
      _newMessagesController.add(newMessages);
    }
    return true;
  }

  static const int _maxRetries = 50;
  final Map<String, int> _retryCounts = {};

  Future<void> _processSendQueue() async {
    if (_isSending || _disposed || TorRuntimeGate.blocked) return;
    _isSending = true;

    int consecutiveFailures = 0;

    try {
      while (!_disposed) {
        await _refreshSession();
        final pending = (await PendingMessageDbHelper.getPendingMessages(groupId: groupId))
            .where((m) => !isGroupControlType(m['type'] as String))
            .toList();
        if (pending.isEmpty) break;

        final sentIds = <String>[];
        bool hadFailure = false;

        for (final msg in pending) {
          if (_disposed) break;

          final pendingId = msg['id'] as String;
          final messageId = _messageIdFromPendingId(pendingId);
          final target = msg['targetMemberId'] as String? ?? msg['receiverId'] as String;
          final retries = _retryCounts[pendingId] ?? 0;

          if (retries >= _maxRetries) {
            sentIds.add(pendingId);
            _retryCounts.remove(pendingId);
            if (!_disposed) {
              _messageStatusController.add(GroupMessageStatusUpdate(messageId, 'failed'));
            }
            continue;
          }

          if (hadFailure) break;

          final success = await _sendOverTor(
            id: messageId,
            targetMemberId: target,
            encrypted: msg['message'] as String,
            type: msg['type'] as String,
            replyToId: msg['replyTo'] as String?,
            timestamp: msg['timestamp'] as int? ?? DateTime.now().millisecondsSinceEpoch,
            fileName: msg['fileName'] as String?,
            fileSize: msg['fileSize'] as int?,
            viewOnce: (msg['viewOnce'] ?? 0) == 1,
          );

          if (success) {
            sentIds.add(pendingId);
            _retryCounts.remove(pendingId);
            consecutiveFailures = 0;
          } else {
            _retryCounts[pendingId] = retries + 1;
            consecutiveFailures++;
            hadFailure = true;
          }
        }

        if (sentIds.isNotEmpty) {
          await PendingMessageDbHelper.removeMessages(sentIds);
          final deliveredMessageIds = sentIds.map(_messageIdFromPendingId).toSet();
          for (final deliveredId in deliveredMessageIds) {
            await _checkAllTargetsDelivered(deliveredId);
          }
        }

        final remaining = (await PendingMessageDbHelper.getPendingMessages(groupId: groupId))
            .where((m) => !isGroupControlType(m['type'] as String))
            .toList();
        if (remaining.isEmpty) break;

        final backoff = min(30, 2 * (1 << min(consecutiveFailures, 4)));
        final jitter = Random().nextInt(max(1, backoff ~/ 2));
        await Future.delayed(Duration(seconds: backoff + jitter));
      }
    } finally {
      _isSending = false;
    }
  }

  Future<bool> _sendOverTor({
    required String id,
    required String targetMemberId,
    required String encrypted,
    required String type,
    String? replyToId,
    required int timestamp,
    String? fileName,
    int? fileSize,
    bool viewOnce = false,
  }) async {
    if (TorRuntimeGate.blocked) return false;

    if (isGroupControlType(type)) {
      try {
        await _postRaw(id, targetMemberId, encrypted, type, timestamp);
        return true;
      } catch (e) {
        print('Group control send failed: $e');
        return false;
      }
    }

    final isLargeMedia = isGroupMessageType(type) && type != groupTextType;
    final timeout =
        isLargeMedia ? const Duration(minutes: 5) : const Duration(seconds: 30);
    try {
      await TorDelivery.withTorRetry<void>(
        attempt: () => _postRaw(
          id,
          targetMemberId,
          encrypted,
          type,
          timestamp,
          replyToId: replyToId,
          fileName: fileName,
          fileSize: fileSize,
          viewOnce: viewOnce,
          timeout: timeout,
        ),
      );
      return true;
    } catch (e) {
      print('Group send failed: $e');
      return false;
    }
  }

  Future<void> _postRaw(
    String id,
    String targetMemberId,
    String encrypted,
    String type,
    int timestamp, {
    String? replyToId,
    String? fileName,
    int? fileSize,
    bool viewOnce = false,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final payload = <String, dynamic>{
      'id': id,
      'senderId': userId,
      'receiverId': targetMemberId,
      'groupId': groupId,
      'message': encrypted,
      'type': type,
      'replyTo': replyToId,
      'timestamp': timestamp,
      'fileName': ?fileName,
      'fileSize': ?fileSize,
      if (viewOnce) 'viewOnce': true,
    };
    await TransportProvider.postMessageOrFallback(
      peerOnion: targetMemberId,
      payload: payload,
      timeout: timeout,
    );
  }

  String _pendingId(String messageId, String targetMemberId) =>
      '${messageId}__$targetMemberId';

  String _messageIdFromPendingId(String pendingId) {
    final idx = pendingId.lastIndexOf('__');
    return idx >= 0 ? pendingId.substring(0, idx) : pendingId;
  }

  Future<void> _addToPendingQueue({
    required String messageId,
    required String targetMemberId,
    required String encrypted,
    required String type,
    String? replyToId,
    required int timestamp,
    String? fileName,
    int? fileSize,
    bool viewOnce = false,
  }) async {
    await PendingMessageDbHelper.insertPendingMessage({
      'id': _pendingId(messageId, targetMemberId),
      'senderId': userId,
      'receiverId': targetMemberId,
      'message': encrypted,
      'type': type,
      'timestamp': timestamp,
      'status': 'pending',
      'replyTo': replyToId,
      'groupId': groupId,
      'targetMemberId': targetMemberId,
      'fileName': ?fileName,
      'fileSize': ?fileSize,
      'viewOnce': viewOnce ? 1 : 0,
    });
  }

  Future<void> _checkAllTargetsDelivered(String messageId) async {
    final remaining = (await PendingMessageDbHelper.getPendingMessages(groupId: groupId))
        .where((m) => !isGroupControlType(m['type'] as String))
        .where((m) => _messageIdFromPendingId(m['id'] as String) == messageId)
        .toList();
    if (remaining.isEmpty) {
      await _markAsSent(messageId);
    }
  }

  /// Retry pending group chat deliveries across all groups (called from app timer).
  static Future<bool> processGlobalPending({
    required String userId,
    required KeyManager keyManager,
    int maxPerCycle = 20,
  }) async {
    final pending = (await PendingMessageDbHelper.getPendingGroupChatMessages(
      senderId: userId,
      limit: maxPerCycle,
    ))
        .where((m) => !isGroupControlType(m['type'] as String))
        .where((m) => m['type'] != groupHistoryRelayType)
        .toList();
    if (pending.isEmpty) return false;

    final groupIds = pending.map((m) => m['groupId'] as String).toSet();
    var anySuccess = false;
    for (final gid in groupIds) {
      final service = GroupChatService(
        userId: userId,
        groupId: gid,
        keyManager: keyManager,
        groupService: GroupService(userId: userId, keyManager: keyManager),
      );
      await service.initialize();
      await service._processPendingOnce();
      anySuccess = true;
      service.dispose();
    }
    return anySuccess;
  }

  Future<void> _processPendingOnce() async {
    if (_isSending || _disposed) return;
    _isSending = true;
    try {
      final pending = (await PendingMessageDbHelper.getPendingMessages(groupId: groupId))
          .where((m) => !isGroupControlType(m['type'] as String))
          .where((m) => m['type'] != groupHistoryRelayType)
          .toList();
      if (pending.isEmpty) return;

      final sentIds = <String>[];
      for (final msg in pending.take(10)) {
        if (_disposed) break;
        final pendingId = msg['id'] as String;
        final messageId = _messageIdFromPendingId(pendingId);
        final stored = await MessagesDb.getMessageById(
          messageId,
          groupId: groupId,
        );
        if (stored.isNotEmpty && stored.first['deletedAt'] != null) {
          await PendingMessageDbHelper.removeOutboundPendingForWireId(
            messageId,
            groupId: groupId,
          );
          continue;
        }
        final encrypted = msg['message'] as String?;
        if (encrypted == null || encrypted.isEmpty) {
          await PendingMessageDbHelper.removeOutboundPendingForWireId(
            messageId,
            groupId: groupId,
          );
          continue;
        }
        final target = msg['targetMemberId'] as String? ?? msg['receiverId'] as String;
        final success = await _sendOverTor(
          id: messageId,
          targetMemberId: target,
          encrypted: encrypted,
          type: msg['type'] as String,
          replyToId: msg['replyTo'] as String?,
          timestamp: msg['timestamp'] as int? ?? DateTime.now().millisecondsSinceEpoch,
          fileName: msg['fileName'] as String?,
          fileSize: msg['fileSize'] as int?,
          viewOnce: (msg['viewOnce'] ?? 0) == 1,
        );
        if (success) {
          sentIds.add(pendingId);
        }
      }
      if (sentIds.isNotEmpty) {
        await PendingMessageDbHelper.removeMessages(sentIds);
        final deliveredMessageIds = sentIds.map(_messageIdFromPendingId).toSet();
        for (final deliveredId in deliveredMessageIds) {
          await _checkAllTargetsDelivered(deliveredId);
        }
      }
    } finally {
      _isSending = false;
    }
  }

  Future<void> _finalizeSendOutcome(
    String messageId,
    int targetCount,
    int successCount,
  ) async {
    if (targetCount == 0 || successCount == targetCount) {
      await _markAsSent(messageId);
    } else if (successCount > 0) {
      await MessagesDb.updateMessageStatus(messageId, 'sent', groupId: groupId);
      _processSendQueue();
    } else {
      await MessagesDb.updateMessageStatus(messageId, 'failed', groupId: groupId);
      if (!_disposed) {
        _messageStatusController.add(GroupMessageStatusUpdate(messageId, 'failed'));
      }
      _processSendQueue();
    }
  }

  Future<void> resendMessage(String messageId) async {
    await _refreshSession();
    if (_groupKey == null) return;

    final rows = await MessagesDb.getMessageById(messageId, groupId: groupId);
    if (rows.isEmpty) return;
    final row = rows.first;

    final encrypted = row['message'] as String?;
    if (encrypted == null || encrypted.isEmpty) return;

    final type = row['type'] as String;
    final timestamp = row['timestamp'] as int;
    final replyToId = row['replyTo'] as String?;
    final fileName = row['fileName'] as String?;
    final fileSize = row['fileSize'] as int?;
    final viewOnce = (row['viewOnce'] ?? 0) == 1;

    await MessagesDb.updateMessageStatus(messageId, 'pending', groupId: groupId);

    final targets = _memberIds.where((m) => m != userId).toList();
    var successCount = 0;

    for (final target in targets) {
      final success = await _sendOverTor(
        id: messageId,
        targetMemberId: target,
        encrypted: encrypted,
        type: type,
        replyToId: replyToId,
        timestamp: timestamp,
        fileName: fileName,
        fileSize: fileSize,
        viewOnce: viewOnce,
      );
      if (success) {
        successCount++;
      } else {
        await _addToPendingQueue(
          messageId: messageId,
          targetMemberId: target,
          encrypted: encrypted,
          type: type,
          replyToId: replyToId,
          timestamp: timestamp,
          fileName: fileName,
          fileSize: fileSize,
          viewOnce: viewOnce,
        );
      }
    }

    await _finalizeSendOutcome(messageId, targets.length, successCount);
  }

  Future<void> _markAsSent(String messageId) async {
    await MessagesDb.updateMessageStatus(messageId, 'sent', groupId: groupId);
    if (!_disposed) {
      _messageStatusController.add(GroupMessageStatusUpdate(messageId, 'sent'));
    }
  }
}

class GroupMessageStatusUpdate {
  final String messageId;
  final String status;
  GroupMessageStatusUpdate(this.messageId, this.status);
}
