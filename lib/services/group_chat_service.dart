import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:prysm/client/TorHttpClient.dart';
import 'package:prysm/constants/group_constants.dart';
import 'package:prysm/database/messages.dart';
import 'package:prysm/services/group_service.dart';
import 'package:prysm/util/group_crypto.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/pending_message_db_helper.dart';
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
  int _pollIntervalSeconds = 2;
  static const int _pollIntervalActive = 2;
  static const int _pollIntervalIdle = 5;
  int _consecutivePollErrors = 0;
  int? _newestTimestamp;
  final Set<String> _seenMessageIds = {};

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
    _newMessagesController.close();
    _messageStatusController.close();
  }

  Future<bool> initialize() async {
    await _refreshSession();
    return _groupKey != null && _memberIds.isNotEmpty;
  }

  Future<void> _refreshSession() async {
    _groupKey = await groupService.getDecryptedGroupKey(groupId);
    final members = await groupService.getMembers(groupId);
    _memberIds = members.map((m) => m.memberId).toList();
  }

  void startPolling() {
    if (_isPolling) return;
    _isPolling = true;
    _loopPoll();
  }

  void stopPolling() {
    _isPolling = false;
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
    final encrypted = GroupCrypto.encryptText(_groupKey!, text);

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
    final encrypted = GroupCrypto.encryptGroupFile(_groupKey!, bytes);

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
        _pollIntervalSeconds = hadNew ? _pollIntervalActive : _pollIntervalIdle;
      } catch (e) {
        print('Group polling error: $e');
        _consecutivePollErrors++;
        _pollIntervalSeconds = min(30, _pollIntervalActive * (1 << _consecutivePollErrors));
      }

      if (_isPolling && !_disposed) {
        await Future.delayed(Duration(seconds: _pollIntervalSeconds));
      }
    }
  }

  Future<bool> _fetchNewMessages() async {
    await _refreshSession();
    final batch = await MessagesDb.getMessagesForGroupBatch(groupId, limit: 20);
    if (batch.isEmpty) return false;

    final newMessages = batch.where((msg) {
      final msgId = msg['id'] as String;
      if (_seenMessageIds.contains(msgId)) return false;
      if (_newestTimestamp != null && (msg['timestamp'] as int) <= _newestTimestamp!) {
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

    _newMessagesController.add(newMessages);
    return true;
  }

  static const int _maxRetries = 50;
  final Map<String, int> _retryCounts = {};

  Future<void> _processSendQueue() async {
    if (_isSending || _disposed) return;
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
    if (isGroupControlType(type)) {
      return _postRaw(id, targetMemberId, encrypted, type, timestamp);
    }

    final isLargeMedia = isGroupMessageType(type) && type != groupTextType;
    for (int attempt = 0; attempt < 2; attempt++) {
      final ok = await _postRaw(
        id,
        targetMemberId,
        encrypted,
        type,
        timestamp,
        replyToId: replyToId,
        fileName: fileName,
        fileSize: fileSize,
        viewOnce: viewOnce,
        timeout: isLargeMedia ? const Duration(minutes: 5) : const Duration(seconds: 30),
      );
      if (ok) return true;
      if (attempt == 0) {
        await Future.delayed(const Duration(seconds: 2));
      }
    }
    return false;
  }

  Future<bool> _postRaw(
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
    final torClient = TorHttpClient(proxyHost: '127.0.0.1', proxyPort: 9050);
    try {
      final uri = Uri.parse('http://$targetMemberId:80/message');
      final body = jsonEncode({
        'id': id,
        'senderId': userId,
        'receiverId': targetMemberId,
        'groupId': groupId,
        'message': encrypted,
        'type': type,
        'replyTo': replyToId,
        'timestamp': timestamp,
        if (fileName != null) 'fileName': fileName,
        if (fileSize != null) 'fileSize': fileSize,
        if (viewOnce) 'viewOnce': true,
      });
      final response = await torClient
          .post(uri, {'Content-Type': 'application/json'}, body)
          .timeout(timeout);
      await response.transform(utf8.decoder).join();
      return true;
    } catch (e) {
      print('Group send failed: $e');
      return false;
    } finally {
      torClient.close();
    }
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
      if (fileName != null) 'fileName': fileName,
      if (fileSize != null) 'fileSize': fileSize,
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
        final target = msg['targetMemberId'] as String? ?? msg['receiverId'] as String;
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
    await MessagesDb.setAsRead(messageId, groupId: groupId);
    if (!_disposed) {
      _messageStatusController.add(GroupMessageStatusUpdate(messageId, 'read'));
    }
  }
}

class GroupMessageStatusUpdate {
  final String messageId;
  final String status;
  GroupMessageStatusUpdate(this.messageId, this.status);
}
