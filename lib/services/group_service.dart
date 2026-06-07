import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:prysm/client/TorHttpClient.dart';
import 'package:prysm/constants/group_constants.dart';
import 'package:prysm/database/messages.dart';
import 'package:prysm/models/group.dart';
import 'package:prysm/services/conversation_preferences_service.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/util/group_crypto.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/group_membership_notifier.dart';
import 'package:prysm/util/pending_message_db_helper.dart';
import 'package:pointycastle/asymmetric/api.dart';
import 'package:uuid/uuid.dart';

class GroupServiceException implements Exception {
  final String message;
  GroupServiceException(this.message);
  @override
  String toString() => message;
}

class GroupService {
  final String userId;
  final KeyManager keyManager;

  final Map<String, Uint8List> _groupKeyCache = {};
  final Map<String, int> _groupKeyVersionCache = {};

  GroupService({required this.userId, required this.keyManager});

  void invalidateGroupKeyCache(String groupId) {
    _groupKeyCache.remove(groupId);
    _groupKeyVersionCache.remove(groupId);
  }

  Future<List<Group>> getGroups() async {
    final maps = await DBHelper.getGroupsForMember(userId);
    final timestamps =
        await MessagesDb.getLastMessageTimestampsForAllGroups(userId);
    return maps
        .map((m) => Group.fromMap(m, lastMessageTimestamp: timestamps[m['id'] as String]))
        .toList();
  }

  Future<bool> isMember(String groupId) =>
      DBHelper.isGroupMember(groupId, userId);

  Future<int?> joinedAtForCurrentUser(String groupId) =>
      DBHelper.getMemberJoinedAt(groupId, userId);

  /// Drops groups that exist locally but no longer list this user as a member.
  Future<int> pruneOrphanedGroups() async {
    final all = await DBHelper.getGroups();
    var pruned = 0;
    for (final row in all) {
      final groupId = row['id'] as String;
      if (!await isMember(groupId)) {
        await deleteGroupLocal(groupId);
        pruned++;
      }
    }
    return pruned;
  }

  Future<List<GroupMember>> getMembers(String groupId) async {
    final maps = await DBHelper.getGroupMembers(groupId);
    return maps.map(GroupMember.fromMap).toList();
  }

  Future<bool> isAdmin(String groupId, String memberId) async {
    final members = await getMembers(groupId);
    return members.any((m) => m.memberId == memberId && m.role == GroupRole.admin);
  }

  Future<Uint8List?> getDecryptedGroupKey(String groupId) async {
    try {
      final row = await DBHelper.getGroupKey(groupId);
      if (row == null) return null;
      final version = row['keyVersion'] as int? ?? 1;
      final cached = _groupKeyCache[groupId];
      if (cached != null && _groupKeyVersionCache[groupId] == version) {
        return cached;
      }
      final key =
          GroupCrypto.decryptGroupKey(row['encryptedKey'] as String, keyManager);
      _groupKeyCache[groupId] = key;
      _groupKeyVersionCache[groupId] = version;
      return key;
    } catch (e) {
      print('Failed to decrypt group key for $groupId: $e');
      return null;
    }
  }

  Future<Group> createGroup(
    String name,
    List<String> memberOnions, {
    String? avatarBase64,
  }) async {
    final uniqueMembers = memberOnions.where((id) => id != userId).toSet().toList();
    final totalCount = 1 + uniqueMembers.length;
    if (totalCount > maxGroupMembers) {
      throw GroupServiceException('Group cannot exceed $maxGroupMembers members');
    }
    if (uniqueMembers.isEmpty) {
      throw GroupServiceException('Select at least one member');
    }

    final groupId = const Uuid().v4();
    final now = DateTime.now().millisecondsSinceEpoch;
    final groupKey = GroupCrypto.generateGroupKey();
    final encryptedForSelf = GroupCrypto.encryptGroupKeyForStorage(groupKey, keyManager);

    await DBHelper.insertGroup({
      'id': groupId,
      'name': name,
      'avatarBase64': avatarBase64,
      'createdBy': userId,
      'createdAt': now,
    });
    await DBHelper.upsertGroupKey(
      groupId: groupId,
      encryptedKey: encryptedForSelf,
      keyVersion: 1,
    );

    final allMembers = <Map<String, String>>[
      {'id': userId, 'role': 'admin'},
      ...uniqueMembers.map((id) => {'id': id, 'role': 'member'}),
    ];

    for (final m in allMembers) {
      await DBHelper.addGroupMember({
        'groupId': groupId,
        'memberId': m['id'],
        'role': m['role'],
        'joinedAt': now,
      });
    }

    for (final memberId in uniqueMembers) {
      await _sendInvite(
        groupId: groupId,
        name: name,
        avatarBase64: avatarBase64,
        members: allMembers,
        groupKey: groupKey,
        keyVersion: 1,
        targetMemberId: memberId,
      );
    }

    return Group(
      id: groupId,
      name: name,
      avatarBase64: avatarBase64,
      createdBy: userId,
      createdAt: now,
    );
  }

  Future<void> updateGroupName(String groupId, String name) async {
    if (!await isAdmin(groupId, userId)) {
      throw GroupServiceException('Only admins can rename the group');
    }
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw GroupServiceException('Group name cannot be empty');
    }

    final group = await DBHelper.getGroupById(groupId);
    if (group == null) throw GroupServiceException('Group not found');

    await DBHelper.insertGroup({
      'id': groupId,
      'name': trimmed,
      'avatarBase64': group['avatarBase64'],
      'createdBy': group['createdBy'],
      'createdAt': group['createdAt'],
    });

    final members = await getMembers(groupId);
    for (final member in members) {
      if (member.memberId == userId) continue;
      await _sendProfileUpdate(
        groupId: groupId,
        name: trimmed,
        avatarBase64: group['avatarBase64'] as String?,
        targetMemberId: member.memberId,
      );
    }
  }

  Future<void> updateGroupAvatar(String groupId, String? avatarBase64) async {
    if (!await isAdmin(groupId, userId)) {
      throw GroupServiceException('Only admins can update group avatar');
    }
    final group = await DBHelper.getGroupById(groupId);
    if (group == null) throw GroupServiceException('Group not found');

    await DBHelper.insertGroup({
      'id': groupId,
      'name': group['name'],
      'avatarBase64': avatarBase64,
      'createdBy': group['createdBy'],
      'createdAt': group['createdAt'],
    });

    final members = await getMembers(groupId);
    for (final member in members) {
      if (member.memberId == userId) continue;
      await _sendProfileUpdate(
        groupId: groupId,
        name: group['name'] as String,
        avatarBase64: avatarBase64,
        targetMemberId: member.memberId,
      );
    }
  }

  /// Re-send invites to all members (idempotent on receivers).
  Future<void> syncMemberInvites(String groupId) async {
    if (!await isAdmin(groupId, userId)) return;

    final group = await DBHelper.getGroupById(groupId);
    if (group == null) return;

    final members = await getMembers(groupId);
    final groupKey = await getDecryptedGroupKey(groupId);
    if (groupKey == null) return;

    final keyRow = await DBHelper.getGroupKey(groupId);
    final keyVersion = keyRow?['keyVersion'] as int? ?? 1;
    final memberMaps = members
        .map((m) => {
              'id': m.memberId,
              'role': m.role == GroupRole.admin ? 'admin' : 'member',
            })
        .toList();

    for (final member in members) {
      if (member.memberId == userId) continue;
      await _sendInvite(
        groupId: groupId,
        name: group['name'] as String,
        avatarBase64: group['avatarBase64'] as String?,
        members: memberMaps,
        groupKey: groupKey,
        keyVersion: keyVersion,
        targetMemberId: member.memberId,
      );
    }
  }

  /// Retry queued group control messages (invites, rotates, etc.).
  /// Processes at most [maxPerCycle] per call; stops early if Tor/proxy is down.
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
      final success = await _postMessage(
        id: id,
        targetMemberId: target,
        groupId: groupId,
        message: wire,
        type: msg['type'] as String,
        quiet: true,
      );

      if (success) {
        sentIds.add(id);
        consecutiveFailures = 0;
      } else {
        consecutiveFailures++;
        if (consecutiveFailures >= 3) break;
      }
    }

    if (sentIds.isNotEmpty) {
      await PendingMessageDbHelper.removeMessages(sentIds);
    }
    return sentIds.isNotEmpty;
  }

  bool _isEncryptedControlWire(String wire) {
    try {
      final parsed = jsonDecode(wire);
      return parsed is Map<String, dynamic> &&
          parsed['envelope'] == GroupCrypto.controlEnvelopeVersion;
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
    return GroupCrypto.encryptControlPayloadForPeer(payload, keyManager, peerKey);
  }

  Future<String?> _buildControlPayload(
    String type,
    Map<String, dynamic> data,
    RSAPublicKey peerKey,
  ) async {
    switch (type) {
      case groupInviteType:
        final groupId = data['groupId'] as String;
        final groupKey = await getDecryptedGroupKey(groupId);
        if (groupKey == null) return null;
        final encryptedGroupKey = GroupCrypto.encryptGroupKeyForMember(
          groupKey,
          keyManager,
          peerKey,
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
        final groupKey = await getDecryptedGroupKey(groupId);
        if (groupKey == null) return null;
        final encryptedGroupKey = GroupCrypto.encryptGroupKeyForMember(
          groupKey,
          keyManager,
          peerKey,
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
      default:
        return null;
    }
  }

  Future<void> addMember(String groupId, String memberOnion) async {
    if (!await isAdmin(groupId, userId)) {
      throw GroupServiceException('Only admins can add members');
    }
    final count = await DBHelper.getGroupMemberCount(groupId);
    if (count >= maxGroupMembers) {
      throw GroupServiceException('Group is full ($maxGroupMembers members max)');
    }
    final existing = await getMembers(groupId);
    if (existing.any((m) => m.memberId == memberOnion)) {
      throw GroupServiceException('Member already in group');
    }

    final group = await DBHelper.getGroupById(groupId);
    if (group == null) throw GroupServiceException('Group not found');

    final groupKey = await getDecryptedGroupKey(groupId);
    if (groupKey == null) throw GroupServiceException('Group key not found');

    final now = DateTime.now().millisecondsSinceEpoch;

    await DBHelper.addGroupMember({
      'groupId': groupId,
      'memberId': memberOnion,
      'role': 'member',
      'joinedAt': now,
    });

    // Re-send invites to every member so existing clients refresh roster + key,
    // and the new member receives their encrypted group key.
    await syncMemberInvites(groupId);
  }

  Future<void> removeMember(String groupId, String memberOnion) async {
    if (!await isAdmin(groupId, userId)) {
      throw GroupServiceException('Only admins can remove members');
    }
    if (memberOnion == userId) {
      throw GroupServiceException('Admin cannot remove themselves; delete the group instead');
    }

    final members = await getMembers(groupId);
    if (!members.any((m) => m.memberId == memberOnion)) {
      throw GroupServiceException('Member not in group');
    }

    await DBHelper.removeGroupMember(groupId, memberOnion);

    final newKey = GroupCrypto.generateGroupKey();
    final keyRow = await DBHelper.getGroupKey(groupId);
    final newVersion = ((keyRow?['keyVersion'] as int?) ?? 1) + 1;
    final encryptedForSelf = GroupCrypto.encryptGroupKeyForStorage(newKey, keyManager);
    await DBHelper.upsertGroupKey(
      groupId: groupId,
      encryptedKey: encryptedForSelf,
      keyVersion: newVersion,
    );

    // Tell the removed member to drop the group (queued if they are offline).
    await _sendKeyRotate(
      groupId: groupId,
      groupKey: newKey,
      keyVersion: newVersion,
      removedMemberId: memberOnion,
      targetMemberId: memberOnion,
    );
    await _sendMemberRemoved(
      groupId: groupId,
      removedMemberId: memberOnion,
      keyVersion: newVersion,
      targetMemberId: memberOnion,
    );

    final remaining = await getMembers(groupId);
    for (final member in remaining) {
      if (member.memberId == userId) continue;
      await _sendKeyRotate(
        groupId: groupId,
        groupKey: newKey,
        keyVersion: newVersion,
        removedMemberId: memberOnion,
        targetMemberId: member.memberId,
      );
      await _sendMemberRemoved(
        groupId: groupId,
        removedMemberId: memberOnion,
        keyVersion: newVersion,
        targetMemberId: member.memberId,
      );
    }
  }

  Future<void> leaveGroup(String groupId) async {
    if (await isAdmin(groupId, userId)) {
      throw GroupServiceException('Admin cannot leave; delete the group instead');
    }

    final members = await getMembers(groupId);
    if (!members.any((m) => m.memberId == userId)) {
      throw GroupServiceException('Not a member of this group');
    }

    await DBHelper.removeGroupMember(groupId, userId);

    final newKey = GroupCrypto.generateGroupKey();
    final keyRow = await DBHelper.getGroupKey(groupId);
    final newVersion = ((keyRow?['keyVersion'] as int?) ?? 1) + 1;
    final encryptedForSelf = GroupCrypto.encryptGroupKeyForStorage(newKey, keyManager);
    await DBHelper.upsertGroupKey(
      groupId: groupId,
      encryptedKey: encryptedForSelf,
      keyVersion: newVersion,
    );

    final remaining = await getMembers(groupId);
    for (final member in remaining) {
      if (member.memberId == userId) continue;
      await _sendKeyRotate(
        groupId: groupId,
        groupKey: newKey,
        keyVersion: newVersion,
        removedMemberId: userId,
        targetMemberId: member.memberId,
      );
      await _sendMemberRemoved(
        groupId: groupId,
        removedMemberId: userId,
        keyVersion: newVersion,
        targetMemberId: member.memberId,
      );
    }

    await deleteGroupLocal(groupId);
  }

  Future<void> deleteGroup(String groupId) async {
    if (!await isAdmin(groupId, userId)) {
      throw GroupServiceException('Only admins can delete the group');
    }

    final members = await getMembers(groupId);
    final keyRow = await DBHelper.getGroupKey(groupId);
    final keyVersion = keyRow?['keyVersion'] as int? ?? 1;

    await deleteGroupLocal(groupId);

    for (final member in members) {
      if (member.memberId == userId) continue;
      _sendMemberRemoved(
        groupId: groupId,
        removedMemberId: userId,
        keyVersion: keyVersion,
        targetMemberId: member.memberId,
      ).catchError((_) {});
    }
  }

  Future<void> deleteGroupLocal(String groupId, {bool notify = true}) async {
    await MessagesDb.deleteMessagesForGroup(groupId);
    await ConversationPreferencesService.instance.delete(groupId);
    await DBHelper.deleteGroup(groupId);
    invalidateGroupKeyCache(groupId);
    if (notify) {
      GroupMembershipNotifier.instance.notifyRemoved(groupId);
    }
  }

  /// Handle incoming control messages (from PrysmServer).
  Future<void> handleIncomingControlMessage(String type, String encryptedPayload) async {
    final plaintext = GroupCrypto.decryptControlPayload(encryptedPayload, keyManager);
    final data = jsonDecode(plaintext) as Map<String, dynamic>;

    switch (type) {
      case groupInviteType:
        await _handleInvite(data);
        break;
      case groupKeyRotateType:
        await _handleKeyRotate(data);
        break;
      case groupMemberRemovedType:
        await _handleMemberRemoved(data);
        break;
      case groupProfileUpdateType:
        await _handleProfileUpdate(data);
        break;
    }
  }

  Future<void> _handleInvite(Map<String, dynamic> data) async {
    final groupId = data['groupId'] as String;
    final name = data['name'] as String;
    final createdBy = data['createdBy'] as String;
    final keyVersion = data['keyVersion'] as int? ?? 1;
    final encryptedGroupKey = data['encryptedGroupKey'] as String;
    final members = (data['members'] as List<dynamic>)
        .map((m) => m as Map<String, dynamic>)
        .toList();

    final existing = await DBHelper.getGroupById(groupId);
    final localKeyRow = await DBHelper.getGroupKey(groupId);
    final localKeyVersion = localKeyRow?['keyVersion'] as int? ?? 0;

    if (localKeyVersion > keyVersion) {
      print('Ignoring stale group invite for $groupId (v$keyVersion < v$localKeyVersion)');
      return;
    }

    final inviteMemberIds = members.map((m) => m['id'] as String).toSet();
    if (existing != null && !inviteMemberIds.contains(userId)) {
      print('Ignoring group invite for $groupId — local user not in roster');
      return;
    }

    final groupKey = GroupCrypto.decryptGroupKeyFromPayload(encryptedGroupKey, keyManager);
    final encryptedForSelf = GroupCrypto.encryptGroupKeyForStorage(groupKey, keyManager);
    final now = DateTime.now().millisecondsSinceEpoch;

    final avatarBase64 = data['avatarBase64'] as String?;
    if (existing == null) {
      await DBHelper.insertGroup({
        'id': groupId,
        'name': name,
        'avatarBase64': avatarBase64,
        'createdBy': createdBy,
        'createdAt': now,
      });
    } else if (avatarBase64 != null) {
      await DBHelper.insertGroup({
        'id': groupId,
        'name': name,
        'avatarBase64': avatarBase64,
        'createdBy': existing['createdBy'],
        'createdAt': existing['createdAt'],
      });
    }

    if (keyVersion > localKeyVersion) {
      await DBHelper.upsertGroupKey(
        groupId: groupId,
        encryptedKey: encryptedForSelf,
        keyVersion: keyVersion,
      );
    }

    final localMembers = existing != null ? await getMembers(groupId) : <GroupMember>[];
    final localMemberIds = localMembers.map((m) => m.memberId).toSet();
    final isNewToGroup = !localMemberIds.contains(userId);

    for (final m in members) {
      final memberId = m['id'] as String;
      final joinedAt = localMemberIds.contains(memberId)
          ? localMembers.firstWhere((lm) => lm.memberId == memberId).joinedAt
          : now;
      await DBHelper.addGroupMember({
        'groupId': groupId,
        'memberId': memberId,
        'role': m['role'] as String,
        'joinedAt': joinedAt,
      });
    }

    if (isNewToGroup) {
      await MessagesDb.deleteGroupMessagesBefore(groupId, now);
    }

    if (keyVersion == localKeyVersion && existing != null) {
      for (final local in localMembers) {
        if (!inviteMemberIds.contains(local.memberId)) {
          await DBHelper.removeGroupMember(groupId, local.memberId);
        }
      }
    }
  }

  Future<void> _handleKeyRotate(Map<String, dynamic> data) async {
    final groupId = data['groupId'] as String;
    final keyVersion = data['keyVersion'] as int;
    final encryptedGroupKey = data['encryptedGroupKey'] as String;
    final removedMemberId = data['removedMemberId'] as String?;

    final localKeyRow = await DBHelper.getGroupKey(groupId);
    final localKeyVersion = localKeyRow?['keyVersion'] as int? ?? 0;
    if (keyVersion <= localKeyVersion) {
      print('Ignoring stale key rotate for $groupId (v$keyVersion <= v$localKeyVersion)');
      return;
    }

    final groupKey = GroupCrypto.decryptGroupKeyFromPayload(encryptedGroupKey, keyManager);
    final encryptedForSelf = GroupCrypto.encryptGroupKeyForStorage(groupKey, keyManager);
    await DBHelper.upsertGroupKey(
      groupId: groupId,
      encryptedKey: encryptedForSelf,
      keyVersion: keyVersion,
    );
    invalidateGroupKeyCache(groupId);

    if (removedMemberId != null && removedMemberId == userId) {
      await deleteGroupLocal(groupId);
    }
  }

  Future<void> _handleMemberRemoved(Map<String, dynamic> data) async {
    final groupId = data['groupId'] as String;
    final removedMemberId = data['removedMemberId'] as String;

    if (removedMemberId == userId) {
      await deleteGroupLocal(groupId);
      return;
    }

    await DBHelper.removeGroupMember(groupId, removedMemberId);
  }

  /// Called when inbound group messages cannot be decrypted — likely key rotated
  /// after this user was removed without receiving the control message.
  Future<void> abandonGroupAfterRemoval(String groupId) async {
    if (!await DBHelper.getGroupById(groupId).then((g) => g != null)) return;
    await deleteGroupLocal(groupId);
  }

  Future<void> _handleProfileUpdate(Map<String, dynamic> data) async {
    final groupId = data['groupId'] as String;
    final name = data['name'] as String?;
    final avatarBase64 = data['avatarBase64'] as String?;

    final existing = await DBHelper.getGroupById(groupId);
    if (existing == null) return;

    await DBHelper.insertGroup({
      'id': groupId,
      'name': name ?? existing['name'],
      'avatarBase64': avatarBase64 ?? existing['avatarBase64'],
      'createdBy': existing['createdBy'],
      'createdAt': existing['createdAt'],
    });
  }

  Future<void> _sendInvite({
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

    final encryptedGroupKey = GroupCrypto.encryptGroupKeyForMember(
      groupKey,
      keyManager,
      peerKey,
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

  Future<void> _sendKeyRotate({
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

    final encryptedGroupKey = GroupCrypto.encryptGroupKeyForMember(
      groupKey,
      keyManager,
      peerKey,
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

  Future<void> _sendProfileUpdate({
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

  Future<void> _sendMemberRemoved({
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

    final encrypted = GroupCrypto.encryptControlPayloadForPeer(payload, keyManager, peerKey);
    final id = const Uuid().v4();
    final success = await _postMessage(
      id: id,
      targetMemberId: targetMemberId,
      groupId: groupId,
      message: encrypted,
      type: type,
    );

    if (!success) {
      await PendingMessageDbHelper.insertPendingMessage({
        'id': id,
        'senderId': userId,
        'receiverId': targetMemberId,
        'message': encrypted,
        'type': type,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'status': 'pending',
        'groupId': groupId,
        'targetMemberId': targetMemberId,
      });
    }
  }

  Future<void> _queuePendingControl({
    required String type,
    required String targetMemberId,
    required String groupId,
    required Map<String, dynamic> body,
  }) async {
    await PendingMessageDbHelper.insertPendingMessage({
      'id': const Uuid().v4(),
      'senderId': userId,
      'receiverId': targetMemberId,
      'message': jsonEncode({
        '_pendingControl': type,
        ...body,
      }),
      'type': type,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'status': 'pending',
      'groupId': groupId,
      'targetMemberId': targetMemberId,
    });
  }

  /// Drop legacy queued history relays — new members no longer receive backlog.
  Future<void> discardPendingHistoryRelay() async {
    final all = await PendingMessageDbHelper.getPendingGroupChatMessages(
      senderId: userId,
      limit: 500,
    );
    final ids = all
        .where((m) => m['type'] == groupHistoryRelayType)
        .map((m) => m['id'] as String)
        .toList();
    if (ids.isNotEmpty) {
      await PendingMessageDbHelper.removeMessages(ids);
    }
  }

  Future<bool> _postMessage({
    required String id,
    required String targetMemberId,
    required String groupId,
    required String message,
    required String type,
    bool quiet = false,
  }) async {
    final torClient = TorHttpClient(proxyHost: '127.0.0.1', proxyPort: 9050);
    try {
      final uri = Uri.parse('http://$targetMemberId:80/message');
      final body = jsonEncode({
        'id': id,
        'senderId': userId,
        'receiverId': targetMemberId,
        'groupId': groupId,
        'message': message,
        'type': type,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      });
      final response = await torClient
          .post(uri, {'Content-Type': 'application/json'}, body)
          .timeout(const Duration(seconds: 30));
      await response.transform(utf8.decoder).join();
      return true;
    } catch (e) {
      if (!quiet) {
        print('Group control send failed: $e');
      }
      return false;
    } finally {
      torClient.close();
    }
  }

  Future<RSAPublicKey?> _fetchPeerPublicKey(String peerId) async {
    final cached = await DBHelper.getUserById(peerId);
    final pem = cached?['publicKeyPem'] as String?;
    if (pem != null && pem.isNotEmpty && pem != 'NONE') {
      try {
        return keyManager.importPeerPublicKey(pem);
      } catch (e) {
        print('Invalid cached peer public key for $peerId: $e');
      }
    }

    final torClient = TorHttpClient(proxyHost: '127.0.0.1', proxyPort: 9050);
    try {
      final uri = Uri.parse('http://$peerId:80/public');
      final response = await torClient.get(uri, {}).timeout(const Duration(seconds: 20));
      final publicKeyPem =
          (await response.transform(utf8.decoder).join()).trim();
      if (publicKeyPem.isNotEmpty) {
        final key = keyManager.importPeerPublicKey(publicKeyPem);
        await DBHelper.updateUserFields(peerId, {'publicKeyPem': publicKeyPem});
        return key;
      }
    } catch (e) {
      print('Failed to fetch peer public key: $e');
    } finally {
      torClient.close();
    }
    return null;
  }
}
