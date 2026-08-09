import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:prysm/transport/transport_provider.dart';
import 'package:prysm/constants/group_constants.dart';
import 'package:prysm/database/messages.dart';
import 'package:prysm/services/group_service.dart';
import 'package:prysm/services/pending_side_channel_queue.dart';
import 'package:prysm/services/side_channel_postman.dart';
import 'package:prysm/services/side_channel_transport.dart';
import 'package:prysm/crypto/group_crypto.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/message_content_wiper.dart';
import 'package:prysm/services/message_search_index_service.dart';
import 'package:prysm/util/message_modify_payload.dart';
import 'package:prysm/util/message_modify_refresh_notifier.dart';
import 'package:prysm/util/pending_message_db_helper.dart';
import 'package:prysm/util/peer_identity_loader.dart';
import 'package:prysm/crypto/identity.dart';
import 'package:prysm/util/logging.dart';

/// Outcome of applying an inbound modify payload, so the transport can
/// decide whether to ack the sender or surface a rejection. The rejection
/// categories need different sender-facing outcomes: an envelope that cannot
/// be authenticated or decrypted is a security rejection, a missing target
/// row is a benign no-op, and an ownership mismatch is a policy violation.
enum InboundModifyOutcome {
  /// The modify authenticated, targeted an existing message row owned by the
  /// sender, and was applied.
  applied,

  /// The envelope could not be authenticated or decrypted (for example a
  /// legacy unsigned `dh-aead` envelope from a pre-v0.7 peer).
  decryptFailed,

  /// The targeted message row does not exist locally.
  unknownTarget,

  /// The targeted message row exists but is owned by a different sender.
  ownershipRejected,
}

class MessageModifyService {
  final String userId;
  final KeyManager keyManager;
  final String? peerId;
  final String? groupId;
  final GroupService? groupService;
  final SideChannelTransport _transport;

  @visibleForTesting
  static Future<bool> Function({
    required String id,
    required String encrypted,
    required int timestamp,
    required String? peerId,
  })? postDirectOverride;

  /// Optional test postman injected into the shared side-channel transport.
  @visibleForTesting
  static SideChannelPostman? testPostman;

  MessageModifyService.direct({
    required this.userId,
    required this.keyManager,
    required this.peerId,
  })  : groupId = null,
        groupService = null,
        _transport = SideChannelTransport(
          userId: userId,
          outbox: const PendingSideChannelQueue(),
          postman: testPostman ?? const _MessageModifyPostman(),
          onDeliveryError: (context, error) => Logging.error(
            'Message modify send failed [$context]: $error',
            'MessageModifyService',
          ),
        );

  MessageModifyService.group({
    required this.userId,
    required this.keyManager,
    required this.groupId,
    required this.groupService,
  })  : peerId = null,
        _transport = SideChannelTransport(
          userId: userId,
          outbox: const PendingSideChannelQueue(),
          postman: testPostman ?? const _MessageModifyPostman(),
          onDeliveryError: (context, error) => Logging.error(
            'Message modify send failed [$context]: $error',
            'MessageModifyService',
          ),
        );

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

    final bool propagated;
    if (groupId != null) {
      propagated = await _sendGroupModify(payload);
    } else {
      propagated = await _sendDirectModify(payload);
    }

    MessageModifyRefreshNotifier.instance.notify(
      MessageModifyUpdate(
        targetMessageId: targetMessageId,
        action: 'delete',
        modifiedAt: modifiedAt,
      ),
    );
    return propagated;
  }

  Future<bool> _editDirectText(
    String targetMessageId,
    String newText,
    int modifiedAt,
  ) async {
    final peerKey = await _loadPeerPublicKey();
    if (peerKey == null) return false;

    final encryptedSelf = await keyManager.encryptForSelf(newText);
    final encryptedPeer = await keyManager.encryptForPeer(
      newText,
      peerKey,
      peerId: peerId!,
    );

    await MessagesDb.updateMessageContent(
      wireId: targetMessageId,
      encryptedMessage: encryptedSelf,
      editedAt: modifiedAt,
    );

    final rows = await MessagesDb.getMessageById(targetMessageId);
    final timestamp = rows.isNotEmpty
        ? rows.first['timestamp'] as int
        : modifiedAt;
    await MessageSearchIndexService.indexBestEffort(
      () => MessageSearchIndexService(
        keyManager: keyManager,
        userId: userId,
      ).reindexEditedMessage(
        messageId: targetMessageId,
        conversationId: peerId!,
        scope: 'direct',
        timestamp: timestamp,
        plaintext: newText,
      ),
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

    final encrypted = await GroupCryptoV2.encryptText(groupKey, newText);
    await MessagesDb.updateMessageContent(
      wireId: targetMessageId,
      groupId: groupId,
      encryptedMessage: encrypted,
      editedAt: modifiedAt,
    );

    final rows = await MessagesDb.getMessageById(
      targetMessageId,
      groupId: groupId,
    );
    final timestamp = rows.isNotEmpty
        ? rows.first['timestamp'] as int
        : modifiedAt;
    await MessageSearchIndexService.indexBestEffort(
      () => MessageSearchIndexService(
        keyManager: keyManager,
        userId: userId,
        groupService: gs,
      ).reindexEditedMessage(
        messageId: targetMessageId,
        conversationId: groupId!,
        scope: 'group',
        timestamp: timestamp,
        plaintext: newText,
      ),
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
        Logging.error('Group message edit send failed: $e', 'MessageModifyService');
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
      Logging.error('Direct message edit send failed: $e', 'MessageModifyService');
    }
    return true;
  }

  /// Returns whether the modify was delivered to the peer right now.
  /// `false` means the send failed (the row is queued for a later retry, or
  /// nothing was attempted: there is no peer id, or the peer's public
  /// identity is unknown and no test override is installed). Callers that
  /// want at-least-once semantics (edits) treat `false` as "queued"; the
  /// delete path reports it as not-yet-propagated.
  Future<bool> _sendDirectModify(MessageModifyPayload payload) async {
    if (peerId == null) return false;

    final override = postDirectOverride;
    final peerKey = await _loadPeerPublicKey();
    if (peerKey == null && override == null) return false;

    final encrypted = peerKey != null
        ? await keyManager.encryptHybridForPeer(
            payload.encode(),
            peerKey,
            peerId: peerId!,
          )
        : '';
    final eventId = modifyEventId(
      targetMessageId: payload.targetMessageId,
      actorId: userId,
      action: payload.action,
      modifiedAt: payload.modifiedAt,
    );

    return _transport.sendDirectAndQueue(
      id: eventId,
      peerId: peerId!,
      encrypted: encrypted,
      timestamp: payload.modifiedAt,
      type: messageModifyType,
    );
  }

  /// Returns whether the modify was delivered to every target right now.
  /// `false` means at least one target send failed (that row is queued for a
  /// later retry, or nothing was attempted: the group service or group key is
  /// unavailable).
  Future<bool> _sendGroupModify(
    MessageModifyPayload payload, {
    Set<String>? onlyTargets,
  }) async {
    final gs = groupService;
    if (gs == null || groupId == null) return false;

    final groupKey = await gs.getDecryptedGroupKey(groupId!);
    if (groupKey == null) return false;

    final encrypted = await GroupCryptoV2.encryptText(groupKey, payload.encode());
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

    var allDelivered = true;
    for (final target in targets) {
      final ok = await _transport.sendGroupAndQueue(
        id: '${eventId}__$target',
        groupId: groupId!,
        targetMemberId: target,
        encrypted: encrypted,
        timestamp: payload.modifiedAt,
        type: groupMessageModifyType,
      );
      if (!ok) allDelivered = false;
    }
    return allDelivered;
  }

  Future<IdentityPublicKeys?> _loadPeerPublicKey() async {
    if (peerId == null) return null;
    try {
      return await loadPeerIdentityFromDb(keyManager, peerId!);
    } catch (e) {
      Logging.error('Failed to load peer public key for $peerId: $e', 'MessageModifyService');
      return null;
    }
  }

  static Future<InboundModifyOutcome> applyInbound({
    required KeyManager keyManager,
    required String localUserId,
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
      senderId: senderId,
      groupId: groupId,
      groupService: groupService,
    );
    if (plaintext == null) {
      Logging.error(
        'Inbound message modify from ${Logging.redactOnion(senderId)} '
        'rejected: could not authenticate or decrypt the envelope',
        'MessageModifyService',
      );
      return InboundModifyOutcome.decryptFailed;
    }

    final payload = MessageModifyPayload.decode(plaintext);
    final rows = await MessagesDb.getMessageById(
      payload.targetMessageId,
      groupId: groupId,
    );
    if (rows.isEmpty) {
      Logging.error(
        'Inbound message modify from ${Logging.redactOnion(senderId)} '
        'targets unknown message ${payload.targetMessageId}',
        'MessageModifyService',
      );
      return InboundModifyOutcome.unknownTarget;
    }
    final row = rows.first;
    if (row['senderId'] != senderId) {
      Logging.error(
        'Inbound message modify from ${Logging.redactOnion(senderId)} '
        'rejected: message ${payload.targetMessageId} is not owned by the sender',
        'MessageModifyService',
      );
      return InboundModifyOutcome.ownershipRejected;
    }

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
        senderId: senderId,
        groupId: groupId,
        groupService: groupService,
      );
      if (newText != null) {
        final indexedText = newText;
        await MessageSearchIndexService.indexBestEffort(
          () => MessageSearchIndexService(
            keyManager: keyManager,
            userId: localUserId,
            groupService: groupService,
          ).reindexEditedMessage(
            messageId: payload.targetMessageId,
            conversationId: groupId ?? senderId,
            scope: groupId != null ? 'group' : 'direct',
            timestamp: row['timestamp'] as int,
            plaintext: indexedText,
          ),
        );
      }
    }

    MessageModifyRefreshNotifier.instance.notify(
      MessageModifyUpdate(
        targetMessageId: payload.targetMessageId,
        action: payload.action,
        newText: newText,
        modifiedAt: payload.modifiedAt,
      ),
    );
    return InboundModifyOutcome.applied;
  }

  static Future<String?> _decryptEditedBody({
    required KeyManager keyManager,
    required String encryptedBody,
    required String type,
    required String senderId,
    String? groupId,
    GroupService? groupService,
  }) async {
    try {
      if (type == messageModifyType) {
        final user = await DBHelper.getUserById(senderId);
        final peerKey = keyManager.tryImportStoredPeerIdentity(
          identityJson: user?['identityJson'] as String?,
          publicKeyPem: user?['publicKeyPem'] as String?,
        );
        if (peerKey == null) return null;
        return keyManager.decryptPeerMessage(
          peerId: senderId,
          wire: encryptedBody,
          peer: peerKey,
        );
      }
      if (type == groupMessageModifyType &&
          groupId != null &&
          groupService != null) {
        final groupKey = await groupService.getDecryptedGroupKey(groupId);
        if (groupKey == null) return null;
        if (GroupCryptoV2.isSenderKeyEnvelope(encryptedBody)) {
          return _decryptSenderKey(
            groupKey: groupKey,
            groupId: groupId,
            wire: encryptedBody,
            transportSenderId: senderId,
            keyManager: keyManager,
          );
        }
        return await GroupCryptoV2.decryptText(groupKey, encryptedBody);
      }
    } catch (e) {
      Logging.error('Edited body decrypt failed: $e', 'MessageModifyService');
    }
    return null;
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
      if (type == messageModifyType) {
        final user = await DBHelper.getUserById(senderId);
        final peerKey = keyManager.tryImportStoredPeerIdentity(
          identityJson: user?['identityJson'] as String?,
          publicKeyPem: user?['publicKeyPem'] as String?,
        );
        if (peerKey == null) return null;
        // Awaited so a decrypt rejection (e.g. a legacy unsigned `dh-aead`
        // envelope) is caught below and reported as `decryptFailed` instead
        // of escaping as an unclassified internal error.
        return await keyManager.decryptPeerMessage(
          peerId: senderId,
          wire: encrypted,
          peer: peerKey,
        );
      }
      if (type == groupMessageModifyType &&
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
      Logging.error(
        'Message modify decrypt failed for ${Logging.redactOnion(senderId)}: $e',
        'MessageModifyService',
      );
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
    final transport = _createTransport(userId);
    return transport.flushPendingForPeer(
      peerId: peerId,
      types: {messageModifyType},
    );
  }

  static Future<bool> processGlobalPendingDirect({
    required String userId,
    required KeyManager keyManager,
    int maxPerCycle = 20,
  }) async {
    final transport = _createTransport(userId);
    return transport.flushGlobalPendingDirect(
      types: {messageModifyType},
      maxPerCycle: maxPerCycle,
    );
  }

  static Future<bool> processGlobalPendingGroup({
    required String userId,
    required KeyManager keyManager,
    int maxPerCycle = 20,
  }) async {
    final transport = _createTransport(userId);
    return transport.flushGlobalPendingGroup(
      types: {groupMessageModifyType},
      maxPerCycle: maxPerCycle,
    );
  }

  static SideChannelTransport _createTransport(String userId) {
    return SideChannelTransport(
      userId: userId,
      outbox: const PendingSideChannelQueue(),
      postman: testPostman ?? const _MessageModifyPostman(),
      onDeliveryError: (context, error) => Logging.error(
        'Message modify pending send failed [$context]: $error',
        'MessageModifyService',
      ),
    );
  }
}

class _MessageModifyPostman implements SideChannelPostman {
  const _MessageModifyPostman();

  @override
  Future<void> postDirect({
    required String peerId,
    required Map<String, dynamic> payload,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final override = MessageModifyService.postDirectOverride;
    if (override != null) {
      final ok = await override(
        id: payload['id'] as String,
        encrypted: payload['message'] as String,
        timestamp: payload['timestamp'] as int,
        peerId: peerId,
      );
      if (!ok) throw Exception('postDirectOverride returned false');
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
    await TransportProvider.postMessageOrFallback(
      peerOnion: targetMemberId,
      payload: payload,
      timeout: timeout,
    );
  }
}
