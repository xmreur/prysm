import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:prysm/constants/group_constants.dart';
import 'package:prysm/database/message_read_receipts.dart';
import 'package:prysm/database/messages.dart';
import 'package:prysm/services/group_service.dart';
import 'package:prysm/services/settings_service.dart';
import 'package:prysm/crypto/group_crypto.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/logging.dart';
import 'package:prysm/services/pending_side_channel_queue.dart';
import 'package:prysm/services/side_channel_postman.dart';
import 'package:prysm/services/side_channel_transport.dart';
import 'package:prysm/util/read_receipt_payload.dart';
import 'package:prysm/util/read_receipt_refresh_notifier.dart';
import 'package:prysm/util/peer_identity_loader.dart';
import 'package:prysm/util/read_waterline_mark.dart';
import 'package:prysm/transport/transport_provider.dart';
import 'package:prysm/crypto/identity.dart';

class ReadReceiptUpdate {
  final String targetMessageId;
  final String? groupId;
  final bool allRead;
  final Map<String, int> readByMemberId;
  final int? readUpToTimestamp;
  final bool isWaterline;

  const ReadReceiptUpdate({
    required this.targetMessageId,
    this.groupId,
    required this.allRead,
    required this.readByMemberId,
    this.readUpToTimestamp,
    this.isWaterline = false,
  });
}

/// Sends, receives, and persists read receipts.
class ReadReceiptService {
  static Future<bool> Function(String peerId)? _flushPendingForPeer;
  static final Map<String, int> _lastDispatchedReadUpTo = {};

  // Test-only overrides for the shared side-channel transport.
  static SideChannelPostman? _postmanForTest;
  static SideChannelOutbox? _outboxForTest;

  @visibleForTesting
  static set postmanForTest(SideChannelPostman postman) =>
      _postmanForTest = postman;

  @visibleForTesting
  static set outboxForTest(SideChannelOutbox outbox) =>
      _outboxForTest = outbox;

  static void configure({
    Future<bool> Function(String peerId)? flushPendingForPeer,
  }) {
    _flushPendingForPeer = flushPendingForPeer;
  }

  @visibleForTesting
  static void resetForTest() {
    _flushPendingForPeer = null;
    _lastDispatchedReadUpTo.clear();
    _postmanForTest = null;
    _outboxForTest = null;
  }

  static String _dispatchKey({
    required String readerId,
    required String? peerId,
    required String? groupId,
  }) {
    if (groupId != null) return '$readerId::group::$groupId';
    return '$readerId::$peerId';
  }

  static SideChannelTransport _buildTransport({required String userId}) =>
      SideChannelTransport(
        userId: userId,
        outbox: _outboxForTest ?? const PendingSideChannelQueue(),
        postman: _postmanForTest ?? const _ReadReceiptPostman(),
        maxAttempts: 2,
      );

  final String userId;
  final KeyManager keyManager;
  final String? peerId;
  final String? groupId;
  final GroupService? groupService;
  final SettingsService _settings = SettingsService();
  SideChannelTransport? _transportForTest;

  @visibleForTesting
  set transportForTest(SideChannelTransport transport) =>
      _transportForTest = transport;

  SideChannelTransport get _transport =>
      _transportForTest ??
      SideChannelTransport(
        userId: userId,
        outbox: _outboxForTest ?? const PendingSideChannelQueue(),
        postman: _postmanForTest ?? const _ReadReceiptPostman(),
        maxAttempts: 2,
        onDeliveryError: (context, error) {
          final label = context.startsWith('group:')
              ? 'Group read waterline'
              : 'Read waterline';
          Logging.warning(
            '$label deferred (will retry via sync): $error',
            'ReadReceiptService',
          );
        },
      );

  ReadReceiptService.direct({
    required this.userId,
    required this.keyManager,
    required this.peerId,
  })  : groupId = null,
        groupService = null;

  ReadReceiptService.group({
    required this.userId,
    required this.keyManager,
    required this.groupId,
    required this.groupService,
  }) : peerId = null;

  /// Send one read waterline for a batch of locally-marked-read messages.
  Future<void> sendWaterline(ReadWaterlineMark mark) async {
    if (!_settings.sendReadReceipts) return;

    final dispatchKey = _dispatchKey(
      readerId: userId,
      peerId: peerId,
      groupId: groupId ?? mark.groupId,
    );
    final lastDispatched = _lastDispatchedReadUpTo[dispatchKey] ?? 0;
    if (mark.readUpToTimestamp <= lastDispatched) {
      if (peerId != null) {
        final flush = _flushPendingForPeer;
        if (flush != null) {
          unawaited(flush(peerId!));
        }
      }
      return;
    }

    final payload = ReadReceiptPayload(
      targetMessageId: mark.latestMessageId,
      readerId: userId,
      groupId: mark.groupId ?? groupId,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      readUpToTimestamp: mark.readUpToTimestamp,
    );

    if (groupId != null) {
      await _sendGroupWaterline(payload);
    } else {
      await _sendDirectWaterline(payload);
    }
  }

  Future<void> _sendDirectWaterline(ReadReceiptPayload payload) async {
    final peerKey = await _loadPeerPublicKey();
    if (peerKey == null || peerId == null) return;

    final encrypted = await keyManager.encryptForPeer(
      payload.encode(),
      peerKey,
      peerId: peerId!,
    );
    final eventId = readWaterlineEventId(
      readerId: userId,
      peerId: peerId!,
    );

    _lastDispatchedReadUpTo[_dispatchKey(readerId: userId, peerId: peerId, groupId: null)] =
        payload.readUpToTimestamp ?? payload.timestamp;

    final ok = await _transport.sendDirectAndQueue(
      id: eventId,
      peerId: peerId!,
      encrypted: encrypted,
      timestamp: payload.timestamp,
      type: readWaterlineType,
      fastFail: true,
    );
    if (!ok) {
      final flush = _flushPendingForPeer;
      if (flush != null) {
        unawaited(flush(peerId!));
      }
    }
  }

  Future<void> _sendGroupWaterline(ReadReceiptPayload payload) async {
    final gs = groupService;
    if (gs == null || groupId == null) return;

    final groupKey = await gs.getDecryptedGroupKey(groupId!);
    if (groupKey == null) return;

    final encrypted = await GroupCryptoV2.encryptText(groupKey, payload.encode());
    final members = await gs.getMembers(groupId!);
    final targets = members.map((m) => m.memberId).where((id) => id != userId);
    final eventId = readWaterlineEventId(
      readerId: userId,
      peerId: userId,
      groupId: groupId,
    );

    _lastDispatchedReadUpTo[
      _dispatchKey(readerId: userId, peerId: null, groupId: groupId)
    ] = payload.readUpToTimestamp ?? payload.timestamp;

    for (final target in targets) {
      final pendingId = '$eventId::$target';
      final ok = await _transport.sendGroupAndQueue(
        id: pendingId,
        groupId: groupId!,
        targetMemberId: target,
        encrypted: encrypted,
        timestamp: payload.timestamp,
        type: groupReadWaterlineType,
        fastFail: true,
      );
      if (!ok) {
        final flush = _flushPendingForPeer;
        if (flush != null) {
          unawaited(flush(target));
        }
      }
    }
  }

  Future<IdentityPublicKeys?> _loadPeerPublicKey() async {
    if (peerId == null) return null;
    return loadPeerIdentityFromDb(keyManager, peerId!);
  }

  static Future<void> applyInbound({
    required KeyManager keyManager,
    required String encrypted,
    required String senderId,
    required String type,
    required String localUserId,
    String? groupId,
    GroupService? groupService,
  }) async {
    final plaintext = await _decryptInbound(
      keyManager: keyManager,
      encrypted: encrypted,
      type: type,
      senderId: senderId,
      groupId: groupId,
      groupService: groupService,
    );
    if (plaintext == null) return;

    final payload = ReadReceiptPayload.decode(plaintext);
    final effectiveGroupId = payload.groupId ?? groupId;

    if (type == readWaterlineType || type == groupReadWaterlineType) {
      await _applyWaterlineInbound(
        payload: payload,
        localUserId: localUserId,
        peerId: senderId,
        effectiveGroupId: effectiveGroupId,
        groupService: groupService,
      );
      return;
    }

    await MessageReadReceiptsDb.upsertReceipt(
      wireMessageId: payload.targetMessageId,
      readerId: payload.readerId,
      readAt: payload.timestamp,
      groupId: effectiveGroupId,
    );

    await _upsertAndNotifyReceipt(
      wireMessageId: payload.targetMessageId,
      readerId: payload.readerId,
      readAt: payload.timestamp,
      effectiveGroupId: effectiveGroupId,
      groupService: groupService,
    );
  }

  static Future<void> _applyWaterlineInbound({
    required ReadReceiptPayload payload,
    required String localUserId,
    required String peerId,
    required String? effectiveGroupId,
    GroupService? groupService,
  }) async {
    final rows = effectiveGroupId == null
        ? await MessagesDb.getOutboundDirectUpToTimestamp(
            senderId: localUserId,
            receiverId: peerId,
            readUpToTimestamp: payload.effectiveReadUpToTimestamp,
          )
        : await MessagesDb.getOutboundGroupUpToTimestamp(
            senderId: localUserId,
            groupId: effectiveGroupId,
            readUpToTimestamp: payload.effectiveReadUpToTimestamp,
          );

    if (rows.isEmpty) return;

    for (final row in rows) {
      final wireId = MessagesDb.wireIdFromStorage(row['id'] as String);
      await MessageReadReceiptsDb.upsertReceipt(
        wireMessageId: wireId,
        readerId: payload.readerId,
        readAt: payload.timestamp,
        groupId: effectiveGroupId,
      );
    }

    await _upsertAndNotifyReceipt(
      wireMessageId: payload.targetMessageId,
      readerId: payload.readerId,
      readAt: payload.timestamp,
      effectiveGroupId: effectiveGroupId,
      groupService: groupService,
      readUpToTimestamp: payload.effectiveReadUpToTimestamp,
      isWaterline: true,
    );
  }

  static Future<void> _upsertAndNotifyReceipt({
    required String wireMessageId,
    required String readerId,
    required int readAt,
    required String? effectiveGroupId,
    GroupService? groupService,
    int? readUpToTimestamp,
    bool isWaterline = false,
  }) async {
    final receipts = await MessageReadReceiptsDb.getReceiptsForMessage(
      wireMessageId: wireMessageId,
      groupId: effectiveGroupId,
    );

    var requiredReadCount = 1;
    if (effectiveGroupId != null && groupService != null) {
      final members = await groupService.getMembers(effectiveGroupId);
      final msgRows = await MessagesDb.getMessageById(
        wireMessageId,
        groupId: effectiveGroupId,
      );
      final authorId =
          msgRows.isNotEmpty ? msgRows.first['senderId'] as String? : null;
      requiredReadCount =
          members.where((m) => m.memberId != authorId).length;
      if (requiredReadCount < 1) requiredReadCount = 1;
    }

    final readByMemberId = <String, int>{
      for (final row in receipts)
        row['readerId'] as String: row['readAt'] as int,
    };

    ReadReceiptRefreshNotifier.instance.notify(
      ReadReceiptUpdate(
        targetMessageId: wireMessageId,
        groupId: effectiveGroupId,
        allRead: receipts.length >= requiredReadCount,
        readByMemberId: readByMemberId,
        readUpToTimestamp: readUpToTimestamp,
        isWaterline: isWaterline,
      ),
    );
  }

  static Future<String?> _decryptInbound({
    required KeyManager keyManager,
    required String encrypted,
    required String type,
    required String senderId,
    String? groupId,
    GroupService? groupService,
  }) async {
    try {
      if (type == readReceiptType || type == readWaterlineType) {
        final user = await DBHelper.getUserById(senderId);
        final peerKey = keyManager.tryImportStoredPeerIdentity(
          identityJson: user?['identityJson'] as String?,
          publicKeyPem: user?['publicKeyPem'] as String?,
        );
        if (peerKey == null) return null;
        return keyManager.decryptPeerMessage(
          peerId: senderId,
          wire: encrypted,
          peer: peerKey,
        );
      }
      if ((type == groupReadReceiptType || type == groupReadWaterlineType) &&
          groupId != null &&
          groupService != null) {
        final groupKey = await groupService.getDecryptedGroupKey(groupId);
        if (groupKey == null) return null;
        if (GroupCryptoV2.isSenderKeyEnvelope(encrypted)) {
          return _decryptSenderKey(
            groupKey: groupKey,
            groupId: groupId,
            wire: encrypted,
            transportSenderId: senderId,
            keyManager: keyManager,
          );
        }
        return await GroupCryptoV2.decryptText(groupKey, encrypted);
      }
    } catch (e) {
      Logging.error('Read receipt decrypt failed: $e', 'ReadReceiptService');
    }
    return null;
  }

  static Future<String> _decryptSenderKey({
    required Uint8List groupKey,
    required String groupId,
    required String wire,
    required String transportSenderId,
    required KeyManager keyManager,
  }) async {
    final senderKeys = await loadPeerIdentityFromDb(
      keyManager,
      transportSenderId,
    );
    if (senderKeys == null) {
      throw ArgumentError('Unknown sender identity');
    }
    return GroupCryptoV2.decryptWithSenderKey(
      epochKey: groupKey,
      groupId: groupId,
      wire: wire,
      transportSenderId: transportSenderId,
      senderKeys: senderKeys,
    );
  }

  static Future<bool> processPendingForPeer({
    required String userId,
    required String peerId,
    required KeyManager keyManager,
  }) async {
    return _buildTransport(userId: userId).flushPendingForPeer(
      peerId: peerId,
      types: {readReceiptType, readWaterlineType},
    );
  }

  static Future<bool> processGlobalPendingDirect({
    required String userId,
    required KeyManager keyManager,
    int maxPerCycle = 20,
  }) async {
    return _buildTransport(userId: userId).flushGlobalPendingDirect(
      types: {readReceiptType, readWaterlineType},
      maxPerCycle: maxPerCycle,
    );
  }

  static Future<bool> processGlobalPendingGroup({
    required String userId,
    required KeyManager keyManager,
    int maxPerCycle = 20,
  }) async {
    return _buildTransport(userId: userId).flushGlobalPendingGroup(
      types: {groupReadReceiptType, groupReadWaterlineType},
      maxPerCycle: maxPerCycle,
    );
  }
}

/// [SideChannelPostman] implementation that delegates to the app's
/// transport layer, preserving the realtime/WebSocket fast path used by
/// read receipts.
class _ReadReceiptPostman implements SideChannelPostman {
  const _ReadReceiptPostman();

  @override
  Future<void> postDirect({
    required String peerId,
    required Map<String, dynamic> payload,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (TransportProvider.isConfigured &&
        TransportProvider.instance.isRealtimeConnected(peerId)) {
      await TransportProvider.instance.wsManager.send(
        peerId,
        'read_update',
        payload: payload,
      );
      return;
    }
    await TransportProvider.postMessageOrFallback(
      peerOnion: peerId,
      payload: payload,
      timeout: timeout,
    );
  }

  @override
  Future<void> postGroup({
    required String targetMemberId,
    required Map<String, dynamic> payload,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (TransportProvider.isConfigured &&
        TransportProvider.instance.isRealtimeConnected(targetMemberId)) {
      await TransportProvider.instance.wsManager.send(
        targetMemberId,
        'read_update',
        payload: payload,
      );
      return;
    }
    await TransportProvider.postMessageOrFallback(
      peerOnion: targetMemberId,
      payload: payload,
      timeout: timeout,
    );
  }
}
