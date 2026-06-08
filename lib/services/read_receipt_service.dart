import 'dart:async';
import 'dart:convert';

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

  Future<void> sendReceiptsForMessages(List<String> wireMessageIds) async {
    if (!_settings.sendReadReceipts || wireMessageIds.isEmpty) return;

    for (final messageId in wireMessageIds) {
      final payload = ReadReceiptPayload(
        targetMessageId: messageId,
        readerId: userId,
        groupId: groupId,
        timestamp: DateTime.now().millisecondsSinceEpoch,
      );
      if (groupId != null) {
        await _sendGroupReceipt(payload);
      } else {
        await _sendDirectReceipt(payload);
      }
    }
  }

  Future<void> _sendDirectReceipt(ReadReceiptPayload payload) async {
    final peerKey = await _loadPeerPublicKey();
    if (peerKey == null) {
      await _queueDirectReceipt(payload, peerKeyMissing: true);
      return;
    }

    final encrypted = keyManager.encryptForPeer(payload.encode(), peerKey);
    final eventId = readReceiptEventId(
      targetMessageId: payload.targetMessageId,
      readerId: userId,
    );

    final ok = await _postDirect(
      id: eventId,
      encrypted: encrypted,
      timestamp: payload.timestamp,
    );
    if (!ok) {
      await _queueDirectReceipt(payload, encrypted: encrypted);
    }
  }

  Future<void> _sendGroupReceipt(ReadReceiptPayload payload) async {
    final gs = groupService;
    if (gs == null || groupId == null) return;

    final groupKey = await gs.getDecryptedGroupKey(groupId!);
    if (groupKey == null) return;

    final encrypted = GroupCrypto.encryptText(groupKey, payload.encode());
    final members = await gs.getMembers(groupId!);
    final targets = members.map((m) => m.memberId).where((id) => id != userId);

    final eventId = readReceiptEventId(
      targetMessageId: payload.targetMessageId,
      readerId: userId,
    );

    for (final target in targets) {
      final ok = await _postGroup(
        id: eventId,
        targetMemberId: target,
        encrypted: encrypted,
        timestamp: payload.timestamp,
      );
      if (!ok) {
        await PendingMessageDbHelper.insertPendingMessage({
          'id': '${eventId}__$target',
          'senderId': userId,
          'receiverId': target,
          'message': encrypted,
          'type': groupReadReceiptType,
          'timestamp': payload.timestamp,
          'status': 'pending',
          'groupId': groupId,
          'targetMemberId': target,
        });
      }
    }
  }

  Future<void> _queueDirectReceipt(
    ReadReceiptPayload payload, {
    String? encrypted,
    bool peerKeyMissing = false,
  }) async {
    if (peerKeyMissing) return;
    final eventId = readReceiptEventId(
      targetMessageId: payload.targetMessageId,
      readerId: userId,
    );
    await PendingMessageDbHelper.insertPendingMessage({
      'id': eventId,
      'senderId': userId,
      'receiverId': peerId,
      'message': encrypted ?? '',
      'type': readReceiptType,
      'timestamp': payload.timestamp,
      'status': 'pending',
    });
  }

  Future<bool> _postDirect({
    required String id,
    required String encrypted,
    required int timestamp,
  }) async {
    if (peerId == null) return false;
    final torClient = TorHttpClient(proxyHost: '127.0.0.1', proxyPort: 9050);
    try {
      final uri = Uri.parse('http://$peerId:80/message');
      final body = jsonEncode({
        'id': id,
        'senderId': userId,
        'receiverId': peerId,
        'message': encrypted,
        'type': readReceiptType,
        'timestamp': timestamp,
      });
      final response = await torClient
          .post(uri, {'Content-Type': 'application/json'}, body)
          .timeout(const Duration(seconds: 30));
      await response.transform(utf8.decoder).join();
      return true;
    } catch (e) {
      print('Read receipt send failed: $e');
      return false;
    } finally {
      torClient.close();
    }
  }

  Future<bool> _postGroup({
    required String id,
    required String targetMemberId,
    required String encrypted,
    required int timestamp,
  }) async {
    if (groupId == null) return false;
    final torClient = TorHttpClient(proxyHost: '127.0.0.1', proxyPort: 9050);
    try {
      final uri = Uri.parse('http://$targetMemberId:80/message');
      final body = jsonEncode({
        'id': id,
        'senderId': userId,
        'receiverId': targetMemberId,
        'groupId': groupId,
        'message': encrypted,
        'type': groupReadReceiptType,
        'timestamp': timestamp,
      });
      final response = await torClient
          .post(uri, {'Content-Type': 'application/json'}, body)
          .timeout(const Duration(seconds: 30));
      await response.transform(utf8.decoder).join();
      return true;
    } catch (e) {
      print('Group read receipt send failed: $e');
      return false;
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

    await MessageReadReceiptsDb.upsertReceipt(
      wireMessageId: payload.targetMessageId,
      readerId: payload.readerId,
      readAt: payload.timestamp,
      groupId: effectiveGroupId,
    );

    final receipts = await MessageReadReceiptsDb.getReceiptsForMessage(
      wireMessageId: payload.targetMessageId,
      groupId: effectiveGroupId,
    );

    var requiredReadCount = 1;
    if (effectiveGroupId != null && groupService != null) {
      final members = await groupService.getMembers(effectiveGroupId);
      final msgRows = await MessagesDb.getMessageById(
        payload.targetMessageId,
        groupId: effectiveGroupId,
      );
      final authorId = msgRows.isNotEmpty
          ? msgRows.first['senderId'] as String?
          : null;
      requiredReadCount = members
          .where((m) => m.memberId != authorId)
          .length;
      if (requiredReadCount < 1) requiredReadCount = 1;
    }

    final readByMemberId = <String, int>{
      for (final row in receipts)
        row['readerId'] as String: row['readAt'] as int,
    };

    ReadReceiptRefreshNotifier.instance.notify(
      ReadReceiptUpdate(
        targetMessageId: payload.targetMessageId,
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
      if (type == readReceiptType) {
        return keyManager.decryptMessage(encrypted);
      }
      if (type == groupReadReceiptType &&
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
    final receipts =
        pending.where((m) => m['type'] == readReceiptType).toList();
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
    final receipts =
        pending.where((m) => m['type'] == readReceiptType).toList();
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
    final receipts =
        pending.where((m) => m['type'] == groupReadReceiptType).toList();
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
        id: _eventIdFromPending(msg['id'] as String),
        targetMemberId: target,
        encrypted: msg['message'] as String,
        timestamp: msg['timestamp'] as int,
      );
      if (ok) {
        await PendingMessageDbHelper.removeMessage(msg['id'] as String);
        any = true;
      }
    }
    return any;
  }

  static String _eventIdFromPending(String pendingId) {
    final idx = pendingId.lastIndexOf('__');
    return idx >= 0 ? pendingId.substring(0, idx) : pendingId;
  }
}
