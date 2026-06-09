import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:prysm/client/TorHttpClient.dart';
import 'package:prysm/constants/group_constants.dart';
import 'package:prysm/database/message_read_receipts.dart';
import 'package:prysm/database/messages.dart';
import 'package:prysm/services/group_service.dart';
import 'package:prysm/services/settings_service.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/util/group_crypto.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/pending_message_db_helper.dart';
import 'package:prysm/util/read_receipt_payload.dart';
import 'package:prysm/util/read_receipt_refresh_notifier.dart';
import 'package:prysm/util/read_waterline_mark.dart';
import 'package:prysm/util/tor_delivery.dart';
import 'package:prysm/util/tor_outbound_gateway.dart';
import 'package:pointycastle/asymmetric/api.dart';

class ReadReceiptUpdate {
  final String targetMessageId;
  final String? groupId;
  final bool allRead;
  final Map<String, int> readByMemberId;

  const ReadReceiptUpdate({
    required this.targetMessageId,
    this.groupId,
    required this.allRead,
    required this.readByMemberId,
  });
}

/// Sends, receives, and persists read receipts.
class ReadReceiptService {
  final String userId;
  final KeyManager keyManager;
  final String? peerId;
  final String? groupId;
  final GroupService? groupService;
  final SettingsService _settings = SettingsService();

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

    final encrypted = keyManager.encryptForPeer(payload.encode(), peerKey);
    final eventId = readWaterlineEventId(
      readerId: userId,
      peerId: peerId!,
    );

    final ok = await _postDirect(
      id: eventId,
      encrypted: encrypted,
      timestamp: payload.timestamp,
      messageType: readWaterlineType,
    );
    if (!ok) {
      await PendingMessageDbHelper.insertPendingMessage({
        'id': eventId,
        'senderId': userId,
        'receiverId': peerId,
        'message': encrypted,
        'type': readWaterlineType,
        'timestamp': payload.timestamp,
        'status': 'pending',
      });
    }
  }

  Future<void> _sendGroupWaterline(ReadReceiptPayload payload) async {
    final gs = groupService;
    if (gs == null || groupId == null) return;

    final groupKey = await gs.getDecryptedGroupKey(groupId!);
    if (groupKey == null) return;

    final encrypted = GroupCrypto.encryptText(groupKey, payload.encode());
    final members = await gs.getMembers(groupId!);
    final targets = members.map((m) => m.memberId).where((id) => id != userId);
    final eventId = readWaterlineEventId(
      readerId: userId,
      peerId: userId,
      groupId: groupId,
    );

    for (final target in targets) {
      final pendingId = '$eventId::$target';
      final ok = await _postGroup(
        id: pendingId,
        targetMemberId: target,
        encrypted: encrypted,
        timestamp: payload.timestamp,
        messageType: groupReadWaterlineType,
      );
      if (!ok) {
        await PendingMessageDbHelper.insertPendingMessage({
          'id': pendingId,
          'senderId': userId,
          'receiverId': target,
          'message': encrypted,
          'type': groupReadWaterlineType,
          'timestamp': payload.timestamp,
          'status': 'pending',
          'groupId': groupId,
          'targetMemberId': target,
        });
      }
    }
  }

  Future<bool> _postDirect({
    required String id,
    required String encrypted,
    required int timestamp,
    required String messageType,
  }) async {
    if (peerId == null) return false;
    try {
      await TorDelivery.withTorRetry<void>(
        maxAttempts: 2,
        attempt: () => _postDirectOnce(
          id: id,
          encrypted: encrypted,
          timestamp: timestamp,
          messageType: messageType,
        ),
      );
      return true;
    } catch (e) {
      debugPrint('Read waterline deferred (will retry via sync): $e');
      return false;
    }
  }

  Future<void> _postDirectOnce({
    required String id,
    required String encrypted,
    required int timestamp,
    required String messageType,
  }) async {
    final payload = {
      'id': id,
      'senderId': userId,
      'receiverId': peerId,
      'message': encrypted,
      'type': messageType,
      'timestamp': timestamp,
    };
    if (TorOutboundGateway.isConfigured) {
      await TorOutboundGateway.instance.postMessage(
        peerOnion: peerId!,
        payload: payload,
      );
      return;
    }
    final torClient = TorHttpClient(proxyHost: '127.0.0.1', proxyPort: 9050);
    try {
      final response = await torClient
          .post(
            Uri.parse('http://$peerId:80/message'),
            {'Content-Type': 'application/json'},
            jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 30));
      await torClient.readUtf8Body(response);
    } finally {
      torClient.close();
    }
  }

  Future<bool> _postGroup({
    required String id,
    required String targetMemberId,
    required String encrypted,
    required int timestamp,
    required String messageType,
  }) async {
    if (groupId == null) return false;
    try {
      await TorDelivery.withTorRetry<void>(
        maxAttempts: 2,
        attempt: () => _postGroupOnce(
          id: id,
          targetMemberId: targetMemberId,
          encrypted: encrypted,
          timestamp: timestamp,
          messageType: messageType,
        ),
      );
      return true;
    } catch (e) {
      debugPrint('Group read waterline deferred (will retry via sync): $e');
      return false;
    }
  }

  Future<void> _postGroupOnce({
    required String id,
    required String targetMemberId,
    required String encrypted,
    required int timestamp,
    required String messageType,
  }) async {
    final payload = {
      'id': id,
      'senderId': userId,
      'receiverId': targetMemberId,
      'groupId': groupId,
      'message': encrypted,
      'type': messageType,
      'timestamp': timestamp,
    };
    if (TorOutboundGateway.isConfigured) {
      await TorOutboundGateway.instance.postMessage(
        peerOnion: targetMemberId,
        payload: payload,
      );
      return;
    }
    final torClient = TorHttpClient(proxyHost: '127.0.0.1', proxyPort: 9050);
    try {
      final response = await torClient
          .post(
            Uri.parse('http://$targetMemberId:80/message'),
            {'Content-Type': 'application/json'},
            jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 30));
      await torClient.readUtf8Body(response);
    } finally {
      torClient.close();
    }
  }

  Future<RSAPublicKey?> _loadPeerPublicKey() async {
    if (peerId == null) return null;
    try {
      final user = await DBHelper.getUserById(peerId!);
      final pem = user?['publicKeyPem'] as String?;
      if (pem == null || pem.isEmpty) return null;
      return keyManager.importPeerPublicKey(pem);
    } catch (_) {
      return null;
    }
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
    );
  }

  static Future<void> _upsertAndNotifyReceipt({
    required String wireMessageId,
    required String readerId,
    required int readAt,
    required String? effectiveGroupId,
    GroupService? groupService,
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
      ),
    );
  }

  static Future<String?> _decryptInbound({
    required KeyManager keyManager,
    required String encrypted,
    required String type,
    String? groupId,
    GroupService? groupService,
  }) async {
    try {
      if (type == readReceiptType || type == readWaterlineType) {
        return keyManager.decryptMessage(encrypted);
      }
      if ((type == groupReadReceiptType || type == groupReadWaterlineType) &&
          groupId != null &&
          groupService != null) {
        final groupKey = await groupService.getDecryptedGroupKey(groupId);
        if (groupKey == null) return null;
        return GroupCrypto.decryptText(groupKey, encrypted);
      }
    } catch (e) {
      print('Read receipt decrypt failed: $e');
    }
    return null;
  }

  static Future<bool> processPendingForPeer({
    required String userId,
    required String peerId,
    required KeyManager keyManager,
  }) async {
    final pending = await PendingMessageDbHelper.getPendingDirectMessagesForReceiver(
      senderId: userId,
      receiverId: peerId,
    );
    final receipts = pending
        .where((m) =>
            m['type'] == readReceiptType || m['type'] == readWaterlineType)
        .toList();
    if (receipts.isEmpty) return false;

    var any = false;
    for (final msg in receipts) {
      final service = ReadReceiptService.direct(
        userId: userId,
        keyManager: keyManager,
        peerId: peerId,
      );
      final encrypted = msg['message'] as String?;
      if (encrypted == null || encrypted.isEmpty) {
        continue;
      }
      final ok = await service._postDirect(
        id: msg['id'] as String,
        encrypted: encrypted,
        timestamp: msg['timestamp'] as int,
        messageType: msg['type'] as String,
      );
      if (ok) {
        await PendingMessageDbHelper.removeMessage(msg['id'] as String);
        any = true;
      }
    }
    return any;
  }

  static Future<bool> processGlobalPendingDirect({
    required String userId,
    required KeyManager keyManager,
    int maxPerCycle = 20,
  }) async {
    final pending = await PendingMessageDbHelper.getPendingDirectMessages(
      senderId: userId,
      limit: maxPerCycle,
    );
    final receipts = pending
        .where((m) =>
            m['type'] == readReceiptType || m['type'] == readWaterlineType)
        .toList();
    if (receipts.isEmpty) return false;

    var any = false;
    for (final msg in receipts) {
      final peer = msg['receiverId'] as String?;
      if (peer == null || peer.isEmpty) continue;

      final service = ReadReceiptService.direct(
        userId: userId,
        keyManager: keyManager,
        peerId: peer,
      );
      final encrypted = msg['message'] as String?;
      if (encrypted == null || encrypted.isEmpty) {
        continue;
      }
      final ok = await service._postDirect(
        id: msg['id'] as String,
        encrypted: encrypted,
        timestamp: msg['timestamp'] as int,
        messageType: msg['type'] as String,
      );
      if (ok) {
        await PendingMessageDbHelper.removeMessage(msg['id'] as String);
        any = true;
      }
    }
    return any;
  }

  static Future<bool> processGlobalPendingGroup({
    required String userId,
    required KeyManager keyManager,
    int maxPerCycle = 20,
  }) async {
    final pending = await PendingMessageDbHelper.getPendingGroupChatMessages(
      senderId: userId,
      limit: maxPerCycle,
    );
    final receipts = pending
        .where((m) =>
            m['type'] == groupReadReceiptType ||
            m['type'] == groupReadWaterlineType)
        .toList();
    if (receipts.isEmpty) return false;

    var any = false;
    for (final msg in receipts) {
      final groupId = msg['groupId'] as String?;
      final target = msg['targetMemberId'] as String? ?? msg['receiverId'] as String?;
      if (groupId == null || target == null) continue;

      final gs = GroupService(userId: userId, keyManager: keyManager);
      final service = ReadReceiptService.group(
        userId: userId,
        keyManager: keyManager,
        groupId: groupId,
        groupService: gs,
      );
      final ok = await service._postGroup(
        id: msg['id'] as String,
        targetMemberId: target,
        encrypted: msg['message'] as String,
        timestamp: msg['timestamp'] as int,
        messageType: msg['type'] as String,
      );
      if (ok) {
        await PendingMessageDbHelper.removeMessage(msg['id'] as String);
        any = true;
      }
    }
    return any;
  }
}
