import 'dart:async';
import 'dart:convert';

import 'package:prysm/client/TorHttpClient.dart';
import 'package:prysm/util/tor_delivery.dart';
import 'package:prysm/util/tor_outbound_gateway.dart';
import 'package:prysm/constants/group_constants.dart';
import 'package:prysm/database/message_reactions.dart';
import 'package:prysm/database/messages.dart';
import 'package:prysm/services/group_service.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/util/group_crypto.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/pending_message_db_helper.dart';
import 'package:prysm/util/reaction_payload.dart';
import 'package:prysm/util/reaction_refresh_notifier.dart';
import 'package:pointycastle/asymmetric/api.dart';

class ReactionUpdate {
  final String targetMessageId;
  final Map<String, List<String>> reactions;

  const ReactionUpdate({
    required this.targetMessageId,
    required this.reactions,
  });
}

/// Sends, receives, and persists message emoji reactions.
class ReactionService {
  final String userId;
  final KeyManager keyManager;
  final String? peerId;
  final String? groupId;
  final GroupService? groupService;

  final _updatesController = StreamController<ReactionUpdate>.broadcast();

  Stream<ReactionUpdate> get onReactionsChanged => _updatesController.stream;

  ReactionService.direct({
    required this.userId,
    required this.keyManager,
    required this.peerId,
  })  : groupId = null,
        groupService = null;

  ReactionService.group({
    required this.userId,
    required this.keyManager,
    required this.groupId,
    required this.groupService,
  }) : peerId = null;

  void dispose() {
    _updatesController.close();
  }

  String _storageId(String wireMessageId) =>
      MessagesDb.scopedId(wireId: wireMessageId, groupId: groupId);

  Future<Map<String, Map<String, List<String>>>> loadReactionsForMessages(
    List<String> wireIds,
  ) {
    return MessageReactionsDb.getReactionsForMessages(wireIds, groupId: groupId);
  }

  Future<void> toggleReaction({
    required String targetMessageId,
    required String emoji,
  }) async {
    final storageId = _storageId(targetMessageId);
    final existing = await MessageReactionsDb.getReactionEmoji(
      targetMessageId: storageId,
      reactorId: userId,
    );

    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final remove = existing == emoji;
    final action = remove ? 'remove' : 'add';
    final effectiveEmoji = remove ? emoji : emoji;

    if (remove) {
      await MessageReactionsDb.removeReaction(
        targetMessageId: storageId,
        reactorId: userId,
      );
    } else {
      await MessageReactionsDb.upsertReaction(
        targetMessageId: storageId,
        reactorId: userId,
        emoji: emoji,
        groupId: groupId,
        timestamp: timestamp,
      );
    }

    await _emitUpdate(targetMessageId);

    final payload = ReactionPayload(
      targetMessageId: targetMessageId,
      emoji: effectiveEmoji,
      action: action,
      timestamp: timestamp,
    );

    if (groupId != null) {
      await _sendGroupReaction(payload);
    } else {
      await _sendDirectReaction(payload);
    }
  }

  Future<void> _emitUpdate(String wireMessageId) async {
    final map = await MessageReactionsDb.getReactionsForMessages(
      [wireMessageId],
      groupId: groupId,
    );
    if (!_updatesController.isClosed) {
      _updatesController.add(
        ReactionUpdate(
          targetMessageId: wireMessageId,
          reactions: map[wireMessageId] ?? const {},
        ),
      );
    }
  }

  Future<void> _sendDirectReaction(ReactionPayload payload) async {
    final peerKey = await _loadPeerPublicKey();
    if (peerKey == null) {
      await _queueDirectReaction(payload, peerKeyMissing: true);
      return;
    }

    final encrypted =
        keyManager.encryptForPeer(payload.encode(), peerKey);
    final eventId = reactionEventId(
      targetMessageId: payload.targetMessageId,
      reactorId: userId,
    );

    final ok = await _postDirect(
      id: eventId,
      encrypted: encrypted,
      timestamp: payload.timestamp,
    );
    if (!ok) {
      await _queueDirectReaction(payload, encrypted: encrypted);
    }
  }

  Future<void> _sendGroupReaction(ReactionPayload payload) async {
    final gs = groupService;
    if (gs == null || groupId == null) return;

    final groupKey = await gs.getDecryptedGroupKey(groupId!);
    if (groupKey == null) return;

    final encrypted = GroupCrypto.encryptText(groupKey, payload.encode());
    final members = await gs.getMembers(groupId!);
    final targets = members.map((m) => m.memberId).where((id) => id != userId);

    final eventId = reactionEventId(
      targetMessageId: payload.targetMessageId,
      reactorId: userId,
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
          'type': groupReactionType,
          'timestamp': payload.timestamp,
          'status': 'pending',
          'groupId': groupId,
          'targetMemberId': target,
        });
      }
    }
  }

  Future<void> _queueDirectReaction(
    ReactionPayload payload, {
    String? encrypted,
    bool peerKeyMissing = false,
  }) async {
    if (peerKeyMissing) return;
    final eventId = reactionEventId(
      targetMessageId: payload.targetMessageId,
      reactorId: userId,
    );
    await PendingMessageDbHelper.insertPendingMessage({
      'id': eventId,
      'senderId': userId,
      'receiverId': peerId,
      'message': encrypted ?? '',
      'type': reactionType,
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
    try {
      final send = () => _postDirectOnce(
        id: id,
        encrypted: encrypted,
        timestamp: timestamp,
      );
      if (TorOutboundGateway.isConfigured) {
        await send();
      } else {
        await TorDelivery.withTorRetry<void>(attempt: send);
      }
      return true;
    } catch (e) {
      print('Reaction send failed: $e');
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
      'type': reactionType,
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
      final send = () => _postGroupOnce(
        id: id,
        targetMemberId: targetMemberId,
        encrypted: encrypted,
        timestamp: timestamp,
      );
      if (TorOutboundGateway.isConfigured) {
        await send();
      } else {
        await TorDelivery.withTorRetry<void>(attempt: send);
      }
      return true;
    } catch (e) {
      print('Group reaction send failed: $e');
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
      'type': groupReactionType,
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

  /// Apply an inbound reaction from PrysmServer or pending retry worker.
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

    final payload = ReactionPayload.decode(plaintext);
    final storageId = MessagesDb.scopedId(
      wireId: payload.targetMessageId,
      groupId: groupId,
    );

    if (payload.isRemove) {
      await MessageReactionsDb.removeReaction(
        targetMessageId: storageId,
        reactorId: senderId,
      );
    } else {
      await MessageReactionsDb.upsertReaction(
        targetMessageId: storageId,
        reactorId: senderId,
        emoji: payload.emoji,
        groupId: groupId,
        timestamp: payload.timestamp,
      );
    }

    final reactions = await MessageReactionsDb.getReactionsForMessages(
      [payload.targetMessageId],
      groupId: groupId,
    );
    ReactionRefreshNotifier.instance.notify(
      ReactionUpdate(
        targetMessageId: payload.targetMessageId,
        reactions: reactions[payload.targetMessageId] ?? const {},
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
      if (type == reactionType) {
        return keyManager.decryptMessage(encrypted);
      }
      if (type == groupReactionType && groupId != null && groupService != null) {
        final groupKey = await groupService.getDecryptedGroupKey(groupId);
        if (groupKey == null) return null;
        return GroupCrypto.decryptText(groupKey, encrypted);
      }
    } catch (e) {
      print('Reaction decrypt failed: $e');
    }
    return null;
  }

  /// Retry pending direct reactions for one peer.
  static Future<bool> processPendingForPeer({
    required String userId,
    required String peerId,
    required KeyManager keyManager,
  }) async {
    final pending = await PendingMessageDbHelper.getPendingDirectMessagesForReceiver(
      senderId: userId,
      receiverId: peerId,
    );
    final reactions =
        pending.where((m) => m['type'] == reactionType).toList();
    if (reactions.isEmpty) return false;

    var any = false;
    for (final msg in reactions) {
      final service = ReactionService.direct(
        userId: userId,
        keyManager: keyManager,
        peerId: peerId,
      );
      final encrypted = msg['message'] as String?;
      if (encrypted == null || encrypted.isEmpty) {
        service.dispose();
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
      service.dispose();
    }
    return any;
  }

  /// Retry pending direct reactions for all peers.
  static Future<bool> processGlobalPendingDirect({
    required String userId,
    required KeyManager keyManager,
    int maxPerCycle = 20,
  }) async {
    final pending = await PendingMessageDbHelper.getPendingDirectMessages(
      senderId: userId,
      limit: maxPerCycle,
    );
    final reactions =
        pending.where((m) => m['type'] == reactionType).toList();
    if (reactions.isEmpty) return false;

    var any = false;
    for (final msg in reactions) {
      final peer = msg['receiverId'] as String?;
      if (peer == null || peer.isEmpty) continue;

      final service = ReactionService.direct(
        userId: userId,
        keyManager: keyManager,
        peerId: peer,
      );
      final encrypted = msg['message'] as String?;
      if (encrypted == null || encrypted.isEmpty) {
        service.dispose();
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
      service.dispose();
    }
    return any;
  }

  /// Retry pending group reactions.
  static Future<bool> processGlobalPendingGroup({
    required String userId,
    required KeyManager keyManager,
    int maxPerCycle = 20,
  }) async {
    final pending = await PendingMessageDbHelper.getPendingGroupChatMessages(
      senderId: userId,
      limit: maxPerCycle,
    );
    final reactions =
        pending.where((m) => m['type'] == groupReactionType).toList();
    if (reactions.isEmpty) return false;

    var any = false;
    for (final msg in reactions) {
      final groupId = msg['groupId'] as String?;
      final target = msg['targetMemberId'] as String? ?? msg['receiverId'] as String?;
      if (groupId == null || target == null) continue;

      final gs = GroupService(userId: userId, keyManager: keyManager);
      final service = ReactionService.group(
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
      service.dispose();
    }
    return any;
  }

  static String _eventIdFromPending(String pendingId) {
    final idx = pendingId.lastIndexOf('__');
    return idx >= 0 ? pendingId.substring(0, idx) : pendingId;
  }
}
