import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:prysm/constants/group_constants.dart';
import 'package:prysm/crypto/constants.dart';
import 'package:prysm/crypto/group_crypto.dart';
import 'package:prysm/crypto/identity.dart';
import 'package:prysm/services/group_key_provider.dart';
import 'package:prysm/services/pending_side_channel_queue.dart';
import 'package:prysm/services/side_channel_postman.dart';
import 'package:prysm/services/side_channel_transport.dart';
import 'package:prysm/transport/transport_provider.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/logging.dart';
import 'package:prysm/util/pending_message_db_helper.dart';
import 'package:uuid/uuid.dart';

/// Sends group control messages (invite / key rotate / member removed /
/// profile update) to individual members and retries the ones queued for
/// later delivery.
///
/// Extracted from [GroupService] (Fase 3.1). Delivery attempts and the
/// pending-queue insert-on-failure path are delegated to
/// [SideChannelTransport] — the same shared transport used by the
/// reaction, read-receipt, and message-modify side channels — instead of
/// duplicating a fourth Tor-retry + pending-queue mechanism. This class
/// only owns the control-message-specific concerns that don't fit that
/// generic contract: payload shape per message type, per-peer public-key
/// resolution (control messages carry the group key re-encrypted for each
/// peer), and resolving a still-unencrypted queued control message —
/// queued because the peer's public key wasn't known yet at send time —
/// back into a wire-ready ciphertext at retry time.
class GroupControlChannel {
  final String userId;
  final KeyManager keyManager;
  final GroupKeyProvider keyProvider;
  final SideChannelTransport _transport;

  GroupControlChannel({
    required this.userId,
    required this.keyManager,
    required this.keyProvider,
    SideChannelTransport? transport,
  }) : _transport = transport ??
            SideChannelTransport(
              userId: userId,
              outbox: const PendingSideChannelQueue(),
              postman: const _GroupControlPostman(),
              onDeliveryError: (context, error) => Logging.error(
                'Group control send failed [$context]: $error',
                'GroupControlChannel',
              ),
            );

  Future<void> sendInvite({
    required String groupId,
    required String name,
    String? avatarBase64,
    required List<Map<String, String>> members,
    required Uint8List groupKey,
    required int keyVersion,
    required String targetMemberId,
  }) async {
    final peerKey = await _fetchPeerPublicKey(targetMemberId);
    if (peerKey == null) {
      await _queuePendingControl(
        type: groupInviteType,
        targetMemberId: targetMemberId,
        groupId: groupId,
        body: {
          'groupId': groupId,
          'name': name,
          'createdBy': userId,
          'members': members,
          'keyVersion': keyVersion,
          'avatarBase64': ?avatarBase64,
        },
      );
      return;
    }

    final encryptedGroupKey = await GroupCryptoV2.encryptGroupKeyForStorage(
      groupKey,
      keyManager.identity,
      peerAgreePublic: peerKey.agreePublic,
    );

    final payload = jsonEncode({
      'groupId': groupId,
      'name': name,
      'createdBy': userId,
      'members': members,
      'encryptedGroupKey': encryptedGroupKey,
      'keyVersion': keyVersion,
      'avatarBase64': ?avatarBase64,
    });

    await _sendControlMessage(
      type: groupInviteType,
      targetMemberId: targetMemberId,
      groupId: groupId,
      payload: payload,
    );
  }

  Future<void> sendKeyRotate({
    required String groupId,
    required Uint8List groupKey,
    required int keyVersion,
    required String removedMemberId,
    required String targetMemberId,
  }) async {
    final peerKey = await _fetchPeerPublicKey(targetMemberId);
    if (peerKey == null) {
      await _queuePendingControl(
        type: groupKeyRotateType,
        targetMemberId: targetMemberId,
        groupId: groupId,
        body: {
          'groupId': groupId,
          'keyVersion': keyVersion,
          'removedMemberId': removedMemberId,
        },
      );
      return;
    }

    final encryptedGroupKey = await GroupCryptoV2.encryptGroupKeyForStorage(
      groupKey,
      keyManager.identity,
      peerAgreePublic: peerKey.agreePublic,
    );

    final payload = jsonEncode({
      'groupId': groupId,
      'encryptedGroupKey': encryptedGroupKey,
      'keyVersion': keyVersion,
      'removedMemberId': removedMemberId,
    });

    await _sendControlMessage(
      type: groupKeyRotateType,
      targetMemberId: targetMemberId,
      groupId: groupId,
      payload: payload,
    );
  }

  Future<void> sendProfileUpdate({
    required String groupId,
    required String name,
    String? avatarBase64,
    required String targetMemberId,
  }) async {
    final payload = jsonEncode({
      'groupId': groupId,
      'name': name,
      'avatarBase64': ?avatarBase64,
    });

    await _sendControlMessage(
      type: groupProfileUpdateType,
      targetMemberId: targetMemberId,
      groupId: groupId,
      payload: payload,
    );
  }

  Future<void> sendDisappearingTimer({
    required String groupId,
    required int? timerSeconds,
    required int updatedAt,
    required String updatedBy,
    required String targetMemberId,
  }) async {
    final payload = jsonEncode({
      'groupId': groupId,
      'timerSeconds': timerSeconds,
      'updatedAt': updatedAt,
      'updatedBy': updatedBy,
    });

    await _sendControlMessage(
      type: groupDisappearingTimerType,
      targetMemberId: targetMemberId,
      groupId: groupId,
      payload: payload,
    );
  }

  Future<void> sendMemberRemoved({
    required String groupId,
    required String removedMemberId,
    required int keyVersion,
    required String targetMemberId,
  }) async {
    final payload = jsonEncode({
      'groupId': groupId,
      'removedMemberId': removedMemberId,
      'keyVersion': keyVersion,
    });

    await _sendControlMessage(
      type: groupMemberRemovedType,
      targetMemberId: targetMemberId,
      groupId: groupId,
      payload: payload,
    );
  }

  /// Retry queued group control messages (invites, rotates, etc.).
  /// Processes at most [maxPerCycle] resolved delivery attempts per call;
  /// stops early after three consecutive failures (resolution or delivery).
  /// Returns true if at least one message was delivered.
  Future<bool> processPendingControlMessages({int maxPerCycle = 20}) async {
    final pending = await PendingMessageDbHelper.getPendingControlMessages(groupControlTypes);
    if (pending.isEmpty) return false;

    final sentIds = <String>[];
    var attempted = 0;
    var consecutiveFailures = 0;

    for (final msg in pending) {
      if (attempted >= maxPerCycle) break;
      if (msg['senderId'] != userId) continue;

      final id = msg['id'] as String;
      final target = msg['targetMemberId'] as String? ?? msg['receiverId'] as String;
      final groupId = msg['groupId'] as String? ?? '';

      final wire = await _resolveControlWire(msg, target);
      if (wire == null) {
        consecutiveFailures++;
        if (consecutiveFailures >= 3) break;
        continue;
      }

      attempted++;
      final ok = await _transport.sendGroup(
        id: id,
        groupId: groupId,
        targetMemberId: target,
        encrypted: wire,
        timestamp: DateTime.now().millisecondsSinceEpoch,
        type: msg['type'] as String,
      );

      if (ok) {
        sentIds.add(id);
        consecutiveFailures = 0;
      } else {
        consecutiveFailures++;
        if (consecutiveFailures >= 3) break;
      }
    }

    if (sentIds.isNotEmpty) {
      await _transport.outbox.removeAll(sentIds);
    }
    return sentIds.isNotEmpty;
  }

  bool _isEncryptedControlWire(String wire) {
    try {
      final parsed = jsonDecode(wire);
      return parsed is Map<String, dynamic> &&
          parsed['crypto'] == CryptoConstants.cryptoVersion &&
          (parsed['scheme'] == CryptoConstants.schemeControlWrap1 ||
              parsed['scheme'] == CryptoConstants.schemeControlWrap2);
    } catch (_) {
      return false;
    }
  }

  Future<String?> _resolveControlWire(
    Map<String, dynamic> msg,
    String targetMemberId,
  ) async {
    final raw = msg['message'] as String;
    if (_isEncryptedControlWire(raw)) return raw;

    Map<String, dynamic>? parsed;
    try {
      parsed = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return raw;
    }

    final pendingType = parsed['_pendingControl'] as String? ?? msg['type'] as String;
    if (!groupControlTypes.contains(pendingType)) return raw;

    final peerKey = await _fetchPeerPublicKey(targetMemberId);
    if (peerKey == null) return null;

    final payload = await _buildControlPayload(pendingType, parsed, peerKey);
    if (payload == null) return null;
    return await GroupCryptoV2.encryptControlPayload(
      payload,
      keyManager.identity,
      peerKey.agreePublic,
    );
  }

  Future<String?> _buildControlPayload(
    String type,
    Map<String, dynamic> data,
    IdentityPublicKeys peerKey,
  ) async {
    switch (type) {
      case groupInviteType:
        final groupId = data['groupId'] as String;
        final groupKey = await keyProvider.getDecryptedGroupKey(groupId);
        if (groupKey == null) return null;
        final encryptedGroupKey = await GroupCryptoV2.encryptGroupKeyForStorage(
          groupKey,
          keyManager.identity,
          peerAgreePublic: peerKey.agreePublic,
        );
        return jsonEncode({
          'groupId': groupId,
          'name': data['name'],
          'createdBy': data['createdBy'] ?? userId,
          'members': data['members'],
          'encryptedGroupKey': encryptedGroupKey,
          'keyVersion': data['keyVersion'] ?? 1,
          if (data['avatarBase64'] != null) 'avatarBase64': data['avatarBase64'],
        });
      case groupKeyRotateType:
        final groupId = data['groupId'] as String;
        final groupKey = await keyProvider.getDecryptedGroupKey(groupId);
        if (groupKey == null) return null;
        final encryptedGroupKey = await GroupCryptoV2.encryptGroupKeyForStorage(
          groupKey,
          keyManager.identity,
          peerAgreePublic: peerKey.agreePublic,
        );
        return jsonEncode({
          'groupId': groupId,
          'encryptedGroupKey': encryptedGroupKey,
          'keyVersion': data['keyVersion'],
          if (data['removedMemberId'] != null) 'removedMemberId': data['removedMemberId'],
        });
      case groupMemberRemovedType:
        return jsonEncode({
          'groupId': data['groupId'],
          'removedMemberId': data['removedMemberId'],
          'keyVersion': data['keyVersion'],
        });
      case groupProfileUpdateType:
        return jsonEncode({
          'groupId': data['groupId'],
          if (data['name'] != null) 'name': data['name'],
          if (data['avatarBase64'] != null) 'avatarBase64': data['avatarBase64'],
        });
      case groupDisappearingTimerType:
        return jsonEncode({
          'groupId': data['groupId'],
          'timerSeconds': data['timerSeconds'],
          'updatedAt': data['updatedAt'],
          'updatedBy': data['updatedBy'],
        });
      default:
        return null;
    }
  }

  Future<void> _sendControlMessage({
    required String type,
    required String targetMemberId,
    required String groupId,
    required String payload,
  }) async {
    final peerKey = await _fetchPeerPublicKey(targetMemberId);
    if (peerKey == null) {
      await _queuePendingControl(
        type: type,
        targetMemberId: targetMemberId,
        groupId: groupId,
        body: jsonDecode(payload) as Map<String, dynamic>,
      );
      return;
    }

    final encrypted = await GroupCryptoV2.encryptControlPayload(
      payload,
      keyManager.identity,
      peerKey.agreePublic,
    );
    final id = const Uuid().v4();
    await _transport.sendGroupAndQueue(
      id: id,
      groupId: groupId,
      targetMemberId: targetMemberId,
      encrypted: encrypted,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      type: type,
    );
  }

  Future<void> _queuePendingControl({
    required String type,
    required String targetMemberId,
    required String groupId,
    required Map<String, dynamic> body,
  }) async {
    await _transport.outbox.insertGroup(
      id: const Uuid().v4(),
      senderId: userId,
      receiverId: targetMemberId,
      message: jsonEncode({
        '_pendingControl': type,
        ...body,
      }),
      type: type,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      groupId: groupId,
      targetMemberId: targetMemberId,
    );
  }

  Future<IdentityPublicKeys?> _fetchPeerPublicKey(String peerId) async {
    final cached = await DBHelper.getUserById(peerId);
    final pem = (cached?['identityJson'] as String?) ??
        (cached?['publicKeyPem'] as String?);
    if (pem != null && pem.isNotEmpty && pem != 'NONE') {
      try {
        return keyManager.importPeerIdentity(pem);
      } catch (e) {
        Logging.error('Invalid cached peer public key for $peerId: $e', 'GroupControlChannel');
      }
    }

    try {
      final publicKeyPem =
          (await TransportProvider.getPublicOrFallback(peerId)).trim();
      if (publicKeyPem.isNotEmpty) {
        final key = keyManager.importPeerIdentity(publicKeyPem);
        await DBHelper.updateUserFields(peerId, {
          'identityJson': publicKeyPem,
          'publicKeyPem': publicKeyPem,
        });
        return key;
      }
    } catch (e) {
      Logging.error('Failed to fetch peer public key: $e', 'GroupControlChannel');
    }
    return null;
  }
}

/// [SideChannelPostman] that delegates to the existing [TransportProvider].
class _GroupControlPostman implements SideChannelPostman {
  const _GroupControlPostman();

  @override
  Future<void> postDirect({
    required String peerId,
    required Map<String, dynamic> payload,
    Duration timeout = const Duration(seconds: 30),
  }) async {
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
