import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:prysm/constants/group_constants.dart';
import 'package:prysm/crypto/group_crypto.dart';
import 'package:prysm/crypto/identity.dart';
import 'package:prysm/database/message_reactions.dart';
import 'package:prysm/database/messages.dart';
import 'package:prysm/services/group_service.dart';
import 'package:prysm/services/pending_side_channel_queue.dart';
import 'package:prysm/services/side_channel_postman.dart';
import 'package:prysm/services/side_channel_transport.dart';
import 'package:prysm/transport/transport_provider.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/logging.dart';
import 'package:prysm/util/peer_identity_loader.dart';
import 'package:prysm/util/reaction_payload.dart';
import 'package:prysm/util/reaction_refresh_notifier.dart';

class ReactionUpdate {
  final String targetMessageId;
  final Map<String, List<String>> reactions;

  const ReactionUpdate({
    required this.targetMessageId,
    required this.reactions,
  });
}

/// Sends, receives, and persists message emoji reactions.
///
/// All transport, retry, and pending-queue behaviour is delegated to the
/// shared [SideChannelTransport] module. This class only builds payloads,
/// encrypts them, persists the local reaction DB, and decrypts inbound
/// reactions.
class ReactionService {
  static final Map<String, SideChannelTransport> _sharedTransports = {};
  static SideChannelTransport? _testTransport;

  /// Test-only override of the shared [SideChannelTransport] used by both
  /// instance methods and the static flush helpers. Consumers are unaffected
  /// because the parameter is optional and the public API remains unchanged.
  static void configure({
    SideChannelTransport? transport,
  }) {
    _testTransport = transport;
  }

  @visibleForTesting
  static void resetForTest() {
    _testTransport = null;
    _sharedTransports.clear();
  }

  static SideChannelTransport _transportFor(String userId) =>
      _testTransport ??
      _sharedTransports.putIfAbsent(userId, () => _defaultTransport(userId));

  static SideChannelTransport _defaultTransport(String userId) =>
      SideChannelTransport(
        userId: userId,
        outbox: const PendingSideChannelQueue(),
        postman: const _TransportProviderPostman(),
        maxAttempts: 3,
        onDeliveryError: (context, error) {
          Logging.error('Reaction delivery failed: $error', 'ReactionService');
        },
      );

  final String userId;
  final KeyManager keyManager;
  final String? peerId;
  final String? groupId;
  final GroupService? groupService;
  final SideChannelTransport _transport;

  final _updatesController = StreamController<ReactionUpdate>.broadcast();

  Stream<ReactionUpdate> get onReactionsChanged => _updatesController.stream;

  ReactionService.direct({
    required this.userId,
    required this.keyManager,
    required this.peerId,
    SideChannelTransport? transport,
  })  : groupId = null,
        groupService = null,
        _transport = transport ?? _testTransport ?? _transportFor(userId);

  ReactionService.group({
    required this.userId,
    required this.keyManager,
    required this.groupId,
    required this.groupService,
    SideChannelTransport? transport,
  })  : peerId = null,
        _transport = transport ?? _testTransport ?? _transportFor(userId);

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
    if (peerKey == null) return;

    final encrypted = await keyManager.encryptForPeer(
      payload.encode(),
      peerKey,
      peerId: peerId!,
    );
    final eventId = reactionEventId(
      targetMessageId: payload.targetMessageId,
      reactorId: userId,
    );

    await _transport.sendDirectAndQueue(
      id: eventId,
      peerId: peerId!,
      encrypted: encrypted,
      timestamp: payload.timestamp,
      type: reactionType,
    );
  }

  Future<void> _sendGroupReaction(ReactionPayload payload) async {
    final gs = groupService;
    if (gs == null || groupId == null) return;

    final groupKey = await gs.getDecryptedGroupKey(groupId!);
    if (groupKey == null) return;

    final encrypted = await GroupCryptoV2.encryptText(groupKey, payload.encode());
    final members = await gs.getMembers(groupId!);
    final targets = members.map((m) => m.memberId).where((id) => id != userId);

    final eventId = reactionEventId(
      targetMessageId: payload.targetMessageId,
      reactorId: userId,
    );

    for (final target in targets) {
      final ok = await _transport.sendGroup(
        id: eventId,
        groupId: groupId!,
        targetMemberId: target,
        encrypted: encrypted,
        timestamp: payload.timestamp,
        type: groupReactionType,
      );
      if (!ok) {
        await _transport.outbox.insertGroup(
          id: '${eventId}__$target',
          senderId: userId,
          receiverId: target,
          message: encrypted,
          type: groupReactionType,
          timestamp: payload.timestamp,
          groupId: groupId!,
          targetMemberId: target,
        );
      }
    }
  }

  Future<IdentityPublicKeys?> _loadPeerPublicKey() async {
    if (peerId == null) return null;
    return loadPeerIdentityFromDb(keyManager, peerId!);
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
      senderId: senderId,
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
    required String senderId,
    String? groupId,
    GroupService? groupService,
  }) async {
    try {
      if (type == reactionType) {
        final user = await DBHelper.getUserById(senderId);
        final identityJson = (user?['identityJson'] as String?) ??
            (user?['publicKeyPem'] as String?);
        if (identityJson == null || identityJson.isEmpty) return null;
        final peerKey = keyManager.importPeerIdentity(identityJson);
        return keyManager.decryptPeerMessage(
          peerId: senderId,
          wire: encrypted,
          peer: peerKey,
        );
      }
      if (type == groupReactionType && groupId != null && groupService != null) {
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
      Logging.error('Reaction decrypt failed: $e', 'ReactionService');
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

  /// Strips the member suffix added to pending group reaction ids so that
  /// retry/flush uses the original wire event id, matching pre-migration
  /// behaviour.
  static String _eventIdFromPending(String pendingId) {
    final idx = pendingId.lastIndexOf('__');
    return idx == -1 ? pendingId : pendingId.substring(0, idx);
  }

  /// Retry pending direct reactions for one peer.
  static Future<bool> processPendingForPeer({
    required String userId,
    required String peerId,
    required KeyManager keyManager,
  }) async {
    return _transportFor(userId).flushPendingForPeer(
      peerId: peerId,
      types: {reactionType},
    );
  }

  /// Retry pending direct reactions for all peers.
  static Future<bool> processGlobalPendingDirect({
    required String userId,
    required KeyManager keyManager,
    int maxPerCycle = 20,
  }) async {
    return _transportFor(userId).flushGlobalPendingDirect(
      types: {reactionType},
      maxPerCycle: maxPerCycle,
    );
  }

  /// Retry pending group reactions.
  static Future<bool> processGlobalPendingGroup({
    required String userId,
    required KeyManager keyManager,
    int maxPerCycle = 20,
  }) async {
    return _transportFor(userId).flushGlobalPendingGroup(
      types: {groupReactionType},
      maxPerCycle: maxPerCycle,
      wireIdOf: (row) => _eventIdFromPending(row.id),
    );
  }
}

/// [SideChannelPostman] that delegates to the existing [TransportProvider].
class _TransportProviderPostman implements SideChannelPostman {
  const _TransportProviderPostman();

  @override
  Future<void> postDirect({
    required String peerId,
    required Map<String, dynamic> payload,
  }) async {
    await TransportProvider.postMessageOrFallback(
      peerOnion: peerId,
      payload: payload,
    );
  }

  @override
  Future<void> postGroup({
    required String targetMemberId,
    required Map<String, dynamic> payload,
  }) async {
    await TransportProvider.postMessageOrFallback(
      peerOnion: targetMemberId,
      payload: payload,
    );
  }
}
