import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:prysm/client/TorHttpClient.dart';
import 'package:prysm/util/tor_delivery.dart';
import 'package:prysm/util/tor_outbound_gateway.dart';
import 'package:prysm/constants/group_constants.dart';
import 'package:prysm/database/messages.dart';
import 'package:prysm/services/group_service.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/util/group_crypto.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/message_content_wiper.dart';
import 'package:prysm/util/message_modify_payload.dart';
import 'package:prysm/util/message_modify_refresh_notifier.dart';
import 'package:prysm/util/pending_message_db_helper.dart';
import 'package:pointycastle/asymmetric/api.dart';

class MessageModifyService {
  final String userId;
  final KeyManager keyManager;
  final String? peerId;
  final String? groupId;
  final GroupService? groupService;

  @visibleForTesting
  static Future<bool> Function({
    required String id,
    required String encrypted,
    required int timestamp,
    required String? peerId,
  })? postDirectOverride;

  MessageModifyService.direct({
    required this.userId,
    required this.keyManager,
    required this.peerId,
  })  : groupId = null,
        groupService = null;

  MessageModifyService.group({
    required this.userId,
    required this.keyManager,
    required this.groupId,
    required this.groupService,
  }) : peerId = null;

  static String modifyEventId({
    required String targetMessageId,
    required String actorId,
    required String action,
    required int modifiedAt,
  }) =>
      'modify::$targetMessageId::$actorId::$action::$modifiedAt';

  Future<bool> editTextMessage({
    required String targetMessageId,
    required String newText,
  }) async {
    final modifiedAt = DateTime.now().millisecondsSinceEpoch;
    if (groupId != null) {
      return _editGroupText(targetMessageId, newText, modifiedAt);
    }
    return _editDirectText(targetMessageId, newText, modifiedAt);
  }

  Future<bool> deleteMessage({required String targetMessageId}) async {
    final modifiedAt = DateTime.now().millisecondsSinceEpoch;
    await MessagesDb.softDeleteMessage(
      targetMessageId,
      groupId: groupId,
      deletedAt: modifiedAt,
    );
    await MessageContentWiper.wipeLocalArtifacts(
      wireId: targetMessageId,
      groupId: groupId,
    );

    final payload = MessageModifyPayload(
      targetMessageId: targetMessageId,
      action: 'delete',
      modifiedAt: modifiedAt,
    );

    if (groupId != null) {
      await _sendGroupModify(payload);
    } else {
      await _sendDirectModify(payload);
    }

    MessageModifyRefreshNotifier.instance.notify(
      MessageModifyUpdate(
        targetMessageId: targetMessageId,
        action: 'delete',
        modifiedAt: modifiedAt,
      ),
    );
    return true;
  }

  Future<bool> _editDirectText(
    String targetMessageId,
    String newText,
    int modifiedAt,
  ) async {
    final peerKey = await _loadPeerPublicKey();
    if (peerKey == null) return false;

    final encryptedSelf = keyManager.encryptForSelf(newText);
    final encryptedPeer = keyManager.encryptForPeer(newText, peerKey);

    await MessagesDb.updateMessageContent(
      wireId: targetMessageId,
      encryptedMessage: encryptedSelf,
      editedAt: modifiedAt,
    );

    _notifyEdit(targetMessageId, newText, modifiedAt);

    final payload = MessageModifyPayload(
      targetMessageId: targetMessageId,
      action: 'edit',
      encryptedBody: encryptedPeer,
      modifiedAt: modifiedAt,
    );

    await syncDirectEditOutbound(
      targetMessageId: targetMessageId,
      encryptedPeer: encryptedPeer,
      payload: payload,
    );

    return true;
  }

  Future<bool> _editGroupText(
    String targetMessageId,
    String newText,
    int modifiedAt,
  ) async {
    final gs = groupService;
    if (gs == null || groupId == null) return false;

    final groupKey = await gs.getDecryptedGroupKey(groupId!);
    if (groupKey == null) return false;

    final encrypted = GroupCrypto.encryptText(groupKey, newText);
    await MessagesDb.updateMessageContent(
      wireId: targetMessageId,
      groupId: groupId,
      encryptedMessage: encrypted,
      editedAt: modifiedAt,
    );

    _notifyEdit(targetMessageId, newText, modifiedAt);

    final payload = MessageModifyPayload(
      targetMessageId: targetMessageId,
      action: 'edit',
      encryptedBody: encrypted,
      modifiedAt: modifiedAt,
    );

    final pendingRows =
        await PendingMessageDbHelper.getPendingGroupOutboundForWireId(
      targetMessageId,
      groupId!,
    );
    for (final row in pendingRows) {
      await PendingMessageDbHelper.updatePendingCiphertext(
        id: row['id'] as String,
        encrypted: encrypted,
      );
    }

    final members = await gs.getMembers(groupId!);
    final allTargets =
        members.map((m) => m.memberId).where((id) => id != userId).toSet();
    final pendingMemberIds = pendingRows
        .map(
          (row) =>
              row['receiverId'] as String? ?? row['targetMemberId'] as String?,
        )
        .whereType<String>()
        .toSet();
    final deliveredTargets = allTargets.difference(pendingMemberIds);

    if (deliveredTargets.isNotEmpty) {
      try {
        await _sendGroupModify(payload, onlyTargets: deliveredTargets);
      } catch (e) {
        print('Group message edit send failed: $e');
      }
    }

    return true;
  }

  void _notifyEdit(String targetMessageId, String newText, int modifiedAt) {
    MessageModifyRefreshNotifier.instance.notify(
      MessageModifyUpdate(
        targetMessageId: targetMessageId,
        action: 'edit',
        newText: newText,
        modifiedAt: modifiedAt,
      ),
    );
  }

  /// Returns true when a modify side-channel send was attempted.
  @visibleForTesting
  Future<bool> syncDirectEditOutbound({
    required String targetMessageId,
    required String encryptedPeer,
    required MessageModifyPayload payload,
  }) async {
    final pending = await PendingMessageDbHelper.getPendingOutboundForWireId(
      targetMessageId,
    );
    if (pending != null) {
      await PendingMessageDbHelper.updatePendingCiphertext(
        id: targetMessageId,
        encrypted: encryptedPeer,
      );
      return false;
    }
    try {
      await _sendDirectModify(payload);
    } catch (e) {
      print('Direct message edit send failed: $e');
    }
    return true;
  }

  Future<void> _sendDirectModify(MessageModifyPayload payload) async {
    if (peerId == null) return;

    final override = postDirectOverride;
    final peerKey = await _loadPeerPublicKey();
    if (peerKey == null && override == null) return;

    final encrypted = peerKey != null
        ? keyManager.encryptHybridForPeer(payload.encode(), peerKey)
        : '';
    final eventId = modifyEventId(
      targetMessageId: payload.targetMessageId,
      actorId: userId,
      action: payload.action,
      modifiedAt: payload.modifiedAt,
    );

    final ok = await _postDirect(
      id: eventId,
      encrypted: encrypted,
      timestamp: payload.modifiedAt,
    );
    if (!ok) {
      await PendingMessageDbHelper.insertPendingMessage({
        'id': eventId,
        'senderId': userId,
        'receiverId': peerId,
        'message': encrypted,
        'type': messageModifyType,
        'timestamp': payload.modifiedAt,
        'status': 'pending',
      });
    }
  }

  Future<void> _sendGroupModify(
    MessageModifyPayload payload, {
    Set<String>? onlyTargets,
  }) async {
    final gs = groupService;
    if (gs == null || groupId == null) return;

    final groupKey = await gs.getDecryptedGroupKey(groupId!);
    if (groupKey == null) return;

    final encrypted = GroupCrypto.encryptText(groupKey, payload.encode());
    final members = await gs.getMembers(groupId!);
    var targets = members.map((m) => m.memberId).where((id) => id != userId);
    if (onlyTargets != null) {
      targets = targets.where(onlyTargets.contains);
    }

    final eventId = modifyEventId(
      targetMessageId: payload.targetMessageId,
      actorId: userId,
      action: payload.action,
      modifiedAt: payload.modifiedAt,
    );

    for (final target in targets) {
      final ok = await _postGroup(
        id: eventId,
        targetMemberId: target,
        encrypted: encrypted,
        timestamp: payload.modifiedAt,
      );
      if (!ok) {
        await PendingMessageDbHelper.insertPendingMessage({
          'id': '${eventId}__$target',
          'senderId': userId,
          'receiverId': target,
          'message': encrypted,
          'type': groupMessageModifyType,
          'timestamp': payload.modifiedAt,
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
  }) async {
    if (peerId == null) return false;
    final override = postDirectOverride;
    if (override != null) {
      return override(
        id: id,
        encrypted: encrypted,
        timestamp: timestamp,
        peerId: peerId,
      );
    }
    try {
      await TorDelivery.withTorRetry<void>(
        attempt: () => _postDirectOnce(
          id: id,
          encrypted: encrypted,
          timestamp: timestamp,
        ),
      );
      return true;
    } catch (e) {
      print('Message modify send failed: $e');
      return false;
    }
  }

  Future<void> _postDirectOnce({
    required String id,
    required String encrypted,
    required int timestamp,
  }) async {
    final payload = {
      'id': id,
      'senderId': userId,
      'receiverId': peerId,
      'message': encrypted,
      'type': messageModifyType,
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
  }) async {
    if (groupId == null) return false;
    try {
      await TorDelivery.withTorRetry<void>(
        attempt: () => _postGroupOnce(
          id: id,
          targetMemberId: targetMemberId,
          encrypted: encrypted,
          timestamp: timestamp,
        ),
      );
      return true;
    } catch (e) {
      print('Group message modify send failed: $e');
      return false;
    }
  }

  Future<void> _postGroupOnce({
    required String id,
    required String targetMemberId,
    required String encrypted,
    required int timestamp,
  }) async {
    final payload = {
      'id': id,
      'senderId': userId,
      'receiverId': targetMemberId,
      'groupId': groupId,
      'message': encrypted,
      'type': groupMessageModifyType,
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
    } catch (e) {
      print('Failed to load peer public key for $peerId: $e');
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

    final payload = MessageModifyPayload.decode(plaintext);
    final rows = await MessagesDb.getMessageById(
      payload.targetMessageId,
      groupId: groupId,
    );
    if (rows.isEmpty) return;
    final row = rows.first;
    if (row['senderId'] != senderId) return;

    String? newText;
    if (payload.isDelete) {
      await MessagesDb.softDeleteMessage(
        payload.targetMessageId,
        groupId: groupId,
        deletedAt: payload.modifiedAt,
      );
      await MessageContentWiper.wipeLocalArtifacts(
        wireId: payload.targetMessageId,
        groupId: groupId,
      );
    } else if (payload.isEdit && payload.encryptedBody != null) {
      await MessagesDb.updateMessageContent(
        wireId: payload.targetMessageId,
        groupId: groupId,
        encryptedMessage: payload.encryptedBody!,
        editedAt: payload.modifiedAt,
      );
      newText = await _decryptEditedBody(
        keyManager: keyManager,
        encryptedBody: payload.encryptedBody!,
        type: type,
        groupId: groupId,
        groupService: groupService,
      );
    }

    MessageModifyRefreshNotifier.instance.notify(
      MessageModifyUpdate(
        targetMessageId: payload.targetMessageId,
        action: payload.action,
        newText: newText,
        modifiedAt: payload.modifiedAt,
      ),
    );
  }

  static Future<String?> _decryptEditedBody({
    required KeyManager keyManager,
    required String encryptedBody,
    required String type,
    String? groupId,
    GroupService? groupService,
  }) async {
    try {
      if (type == messageModifyType) {
        return keyManager.decryptMessage(encryptedBody);
      }
      if (type == groupMessageModifyType &&
          groupId != null &&
          groupService != null) {
        final groupKey = await groupService.getDecryptedGroupKey(groupId);
        if (groupKey == null) return null;
        return GroupCrypto.decryptText(groupKey, encryptedBody);
      }
    } catch (e) {
      print('Edited body decrypt failed: $e');
    }
    return null;
  }

  static Future<String?> _decryptInbound({
    required KeyManager keyManager,
    required String encrypted,
    required String type,
    String? groupId,
    GroupService? groupService,
  }) async {
    try {
      if (type == messageModifyType) {
        if (KeyManager.isHybridEnvelope(encrypted)) {
          return keyManager.decryptHybridEnvelope(encrypted);
        }
        return keyManager.decryptMessage(encrypted);
      }
      if (type == groupMessageModifyType &&
          groupId != null &&
          groupService != null) {
        final groupKey = await groupService.getDecryptedGroupKey(groupId);
        if (groupKey == null) return null;
        return GroupCrypto.decryptText(groupKey, encrypted);
      }
    } catch (e) {
      print('Message modify decrypt failed: $e');
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
    final modifies =
        pending.where((m) => m['type'] == messageModifyType).toList();
    if (modifies.isEmpty) return false;

    var any = false;
    for (final row in modifies) {
      final service = MessageModifyService.direct(
        userId: userId,
        keyManager: keyManager,
        peerId: peerId,
      );
      final ok = await service._postDirect(
        id: row['id'] as String,
        encrypted: row['message'] as String,
        timestamp: row['timestamp'] as int,
      );
      if (ok) {
        await PendingMessageDbHelper.removeMessages([row['id'] as String]);
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
    final modifies =
        pending.where((m) => m['type'] == messageModifyType).toList();
    if (modifies.isEmpty) return false;

    var any = false;
    for (final row in modifies) {
      final peerId = row['receiverId'] as String?;
      if (peerId == null || peerId.isEmpty) continue;
      final service = MessageModifyService.direct(
        userId: userId,
        keyManager: keyManager,
        peerId: peerId,
      );
      final ok = await service._postDirect(
        id: row['id'] as String,
        encrypted: row['message'] as String,
        timestamp: row['timestamp'] as int,
      );
      if (ok) {
        await PendingMessageDbHelper.removeMessages([row['id'] as String]);
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
    final modifies =
        pending.where((m) => m['type'] == groupMessageModifyType).toList();
    if (modifies.isEmpty) return false;

    var any = false;
    for (final row in modifies) {
      final groupId = row['groupId'] as String?;
      final target = row['receiverId'] as String?;
      if (groupId == null || target == null) continue;
      final gs = GroupService(userId: userId, keyManager: keyManager);
      final service = MessageModifyService.group(
        userId: userId,
        keyManager: keyManager,
        groupId: groupId,
        groupService: gs,
      );
      final ok = await service._postGroup(
        id: row['id'] as String,
        targetMemberId: target,
        encrypted: row['message'] as String,
        timestamp: row['timestamp'] as int,
      );
      if (ok) {
        await PendingMessageDbHelper.removeMessages([row['id'] as String]);
        any = true;
      }
    }
    return any;
  }
}
