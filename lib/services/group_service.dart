import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:prysm/util/logging.dart';
import 'package:prysm/constants/group_constants.dart';
import 'package:prysm/database/messages.dart';
import 'package:prysm/models/group.dart';
import 'package:prysm/models/group_invite_mode.dart';
import 'package:prysm/services/conversation_preferences_service.dart';
import 'package:prysm/services/disappearing_timer_service.dart';
import 'package:prysm/services/group_control_channel.dart';
import 'package:prysm/services/group_key_provider.dart';
import 'package:prysm/services/settings_service.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/crypto/group_crypto.dart';
import 'package:prysm/crypto/identity.dart';
import 'package:prysm/util/group_moderation_policy.dart';
import 'package:prysm/util/group_pending_invite_store.dart';
import 'package:prysm/util/group_sender_index_store.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/group_membership_notifier.dart';
import 'package:prysm/util/peer_identity_loader.dart';
import 'package:prysm/util/pending_message_db_helper.dart';
import 'package:uuid/uuid.dart';

class GroupServiceException implements Exception {
  final String message;
  GroupServiceException(this.message);
  @override
  String toString() => message;
}

/// Group membership CRUD (groups, members, roles) and orchestration.
///
/// Key caching/decryption and control-message sending/retry are delegated
/// to [GroupKeyProvider] and [GroupControlChannel] respectively (Fase 3.1
/// split). Handling of *inbound* control messages stays here: it mutates
/// group/member state directly and is squarely membership orchestration,
/// not transport.
class GroupService {
  final String userId;
  final KeyManager keyManager;
  final SettingsService _settings = SettingsService();

  late final GroupKeyProvider _keyProvider;
  late final GroupControlChannel _controlChannel;

  GroupService({
    required this.userId,
    required this.keyManager,
    GroupKeyProvider? keyProvider,
    GroupControlChannel? controlChannel,
  }) {
    _keyProvider = keyProvider ?? GroupKeyProvider(keyManager: keyManager);
    _controlChannel = controlChannel ??
        GroupControlChannel(
          userId: userId,
          keyManager: keyManager,
          keyProvider: _keyProvider,
        );
  }

  void invalidateGroupKeyCache(String groupId) {
    _keyProvider.invalidate(groupId);
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
    final role = await _roleOf(groupId, memberId);
    return role != null && groupRoleIsModerator(role);
  }

  Future<bool> isOwner(String groupId, String memberId) async {
    return await _roleOf(groupId, memberId) == GroupRole.owner;
  }

  Future<bool> isMuted(String groupId, String memberId) async {
    final members = await getMembers(groupId);
    return members.any((m) => m.memberId == memberId && m.muted);
  }

  Future<GroupRole?> _roleOf(String groupId, String memberId) async {
    final members = await getMembers(groupId);
    for (final m in members) {
      if (m.memberId == memberId) return m.role;
    }
    return null;
  }

  Future<GroupMember?> _memberOf(String groupId, String memberId) async {
    final members = await getMembers(groupId);
    for (final m in members) {
      if (m.memberId == memberId) return m;
    }
    return null;
  }

  Future<void> _fanout(
    String groupId,
    Future<void> Function(String targetId) send,
  ) async {
    final members = await getMembers(groupId);
    for (final member in members) {
      if (member.memberId == userId) continue;
      await send(member.memberId);
    }
  }

  Future<Uint8List?> getDecryptedGroupKey(String groupId) =>
      _keyProvider.getDecryptedGroupKey(groupId);

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
    final groupKey = GroupCryptoV2.generateGroupKey();
    final encryptedForSelf = await GroupCryptoV2.encryptGroupKeyForStorage(
      groupKey,
      keyManager.identity,
    );

    await DBHelper.insertGroup({
      'id': groupId,
      'name': name,
      'avatarBase64': avatarBase64,
      'createdBy': userId,
      'createdAt': now,
      'onlyAdminsCanAdd': 1,
    });
    await DBHelper.upsertGroupKey(
      groupId: groupId,
      encryptedKey: encryptedForSelf,
      keyVersion: 1,
    );

    final allMembers = <Map<String, String>>[
      {'id': userId, 'role': 'owner', 'muted': '0'},
      ...uniqueMembers.map((id) => {'id': id, 'role': 'member', 'muted': '0'}),
    ];

    for (final m in allMembers) {
      await DBHelper.addGroupMember({
        'groupId': groupId,
        'memberId': m['id'],
        'role': m['role'],
        'joinedAt': now,
        'muted': 0,
      });
    }

    for (final memberId in uniqueMembers) {
      await _controlChannel.sendInvite(
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

    await DBHelper.updateGroupFields(groupId, {'name': trimmed});

    final members = await getMembers(groupId);
    for (final member in members) {
      if (member.memberId == userId) continue;
      await _controlChannel.sendProfileUpdate(
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

    await DBHelper.updateGroupFields(groupId, {'avatarBase64': avatarBase64});

    final members = await getMembers(groupId);
    for (final member in members) {
      if (member.memberId == userId) continue;
      await _controlChannel.sendProfileUpdate(
        groupId: groupId,
        name: group['name'] as String,
        avatarBase64: avatarBase64,
        targetMemberId: member.memberId,
      );
    }
  }

  /// Re-send invites to all members (idempotent on receivers).
  Future<void> syncMemberInvites(String groupId) async {
    final actor = await _memberOf(groupId, userId);
    final group = await DBHelper.getGroupById(groupId);
    if (actor == null || group == null) return;
    final onlyAdmins = (group['onlyAdminsCanAdd'] ?? 1) == 1;
    if (!canAddMembers(actor: actor.role, onlyAdminsCanAdd: onlyAdmins)) {
      return;
    }

    final members = await getMembers(groupId);
    final groupKey = await getDecryptedGroupKey(groupId);
    if (groupKey == null) return;

    final keyRow = await DBHelper.getGroupKey(groupId);
    final keyVersion = keyRow?['keyVersion'] as int? ?? 1;
    final memberMaps = members
        .map((m) => {
              'id': m.memberId,
              'role': groupRoleToWire(m.role),
              'muted': m.muted ? '1' : '0',
            })
        .toList();

    for (final member in members) {
      if (member.memberId == userId) continue;
      await _controlChannel.sendInvite(
        groupId: groupId,
        name: group['name'] as String,
        avatarBase64: group['avatarBase64'] as String?,
        members: memberMaps,
        groupKey: groupKey,
        keyVersion: keyVersion,
        targetMemberId: member.memberId,
        onlyAdminsCanAdd: onlyAdmins,
      );
    }
  }

  /// Retry queued group control messages (invites, rotates, etc.).
  /// Processes at most [maxPerCycle] per call; stops early if Tor/proxy is down.
  /// Returns true if at least one message was delivered.
  Future<bool> processPendingControlMessages({int maxPerCycle = 20}) =>
      _controlChannel.processPendingControlMessages(maxPerCycle: maxPerCycle);

  Future<void> syncDisappearingTimer({
    required String groupId,
    required List<String> memberIds,
    required int? timerSeconds,
    required int updatedAt,
  }) async {
    for (final target in memberIds.where((m) => m != userId)) {
      await _controlChannel.sendDisappearingTimer(
        groupId: groupId,
        timerSeconds: timerSeconds,
        updatedAt: updatedAt,
        updatedBy: userId,
        targetMemberId: target,
      );
    }
  }

  Future<void> addMember(String groupId, String memberOnion) async {
    final actor = await _memberOf(groupId, userId);
    final group = await DBHelper.getGroupById(groupId);
    if (actor == null || group == null) {
      throw GroupServiceException('Group not found');
    }
    final onlyAdmins = (group['onlyAdminsCanAdd'] ?? 1) == 1;
    if (!canAddMembers(actor: actor.role, onlyAdminsCanAdd: onlyAdmins)) {
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

    final groupKey = await getDecryptedGroupKey(groupId);
    if (groupKey == null) throw GroupServiceException('Group key not found');

    final now = DateTime.now().millisecondsSinceEpoch;

    await DBHelper.addGroupMember({
      'groupId': groupId,
      'memberId': memberOnion,
      'role': 'member',
      'joinedAt': now,
      'muted': 0,
    });

    // Re-send invites to every member so existing clients refresh roster + key,
    // and the new member receives their encrypted group key.
    await syncMemberInvites(groupId);
  }

  Future<void> removeMember(String groupId, String memberOnion) async {
    final actor = await _memberOf(groupId, userId);
    final target = await _memberOf(groupId, memberOnion);
    if (actor == null) {
      throw GroupServiceException('Only admins can remove members');
    }
    if (target == null) {
      throw GroupServiceException('Member not in group');
    }
    if (!canMuteOrKick(
      actor: actor.role,
      target: target.role,
      isSelf: memberOnion == userId,
    )) {
      throw GroupServiceException('Cannot remove this member');
    }

    await DBHelper.removeGroupMember(groupId, memberOnion);

    final newKey = GroupCryptoV2.generateGroupKey();
    final keyRow = await DBHelper.getGroupKey(groupId);
    final newVersion = ((keyRow?['keyVersion'] as int?) ?? 1) + 1;
    final encryptedForSelf = await GroupCryptoV2.encryptGroupKeyForStorage(
      newKey,
      keyManager.identity,
    );
    await DBHelper.upsertGroupKey(
      groupId: groupId,
      encryptedKey: encryptedForSelf,
      keyVersion: newVersion,
    );

    // Tell the removed member to drop the group (queued if they are offline).
    // Never send them the new key: doing so would let them decrypt the group
    // forever (broken forward access revocation).
    await _controlChannel.sendMemberRemoved(
      groupId: groupId,
      removedMemberId: memberOnion,
      keyVersion: newVersion,
      targetMemberId: memberOnion,
    );

    final remaining = await getMembers(groupId);
    for (final member in remaining) {
      if (member.memberId == userId) continue;
      await _controlChannel.sendKeyRotate(
        groupId: groupId,
        groupKey: newKey,
        keyVersion: newVersion,
        removedMemberId: memberOnion,
        targetMemberId: member.memberId,
      );
      await _controlChannel.sendMemberRemoved(
        groupId: groupId,
        removedMemberId: memberOnion,
        keyVersion: newVersion,
        targetMemberId: member.memberId,
      );
    }
  }

  Future<void> leaveGroup(String groupId) async {
    final actor = await _memberOf(groupId, userId);
    if (actor == null) {
      throw GroupServiceException('Not a member of this group');
    }
    if (!canLeaveWithoutTransfer(actor.role)) {
      throw GroupServiceException('Owner cannot leave; transfer ownership first');
    }

    final members = await getMembers(groupId);
    if (!members.any((m) => m.memberId == userId)) {
      throw GroupServiceException('Not a member of this group');
    }

    await DBHelper.removeGroupMember(groupId, userId);

    final newKey = GroupCryptoV2.generateGroupKey();
    final keyRow = await DBHelper.getGroupKey(groupId);
    final newVersion = ((keyRow?['keyVersion'] as int?) ?? 1) + 1;
    final encryptedForSelf = await GroupCryptoV2.encryptGroupKeyForStorage(
      newKey,
      keyManager.identity,
    );
    await DBHelper.upsertGroupKey(
      groupId: groupId,
      encryptedKey: encryptedForSelf,
      keyVersion: newVersion,
    );

    final remaining = await getMembers(groupId);
    for (final member in remaining) {
      if (member.memberId == userId) continue;
      await _controlChannel.sendKeyRotate(
        groupId: groupId,
        groupKey: newKey,
        keyVersion: newVersion,
        removedMemberId: userId,
        targetMemberId: member.memberId,
      );
      await _controlChannel.sendMemberRemoved(
        groupId: groupId,
        removedMemberId: userId,
        keyVersion: newVersion,
        targetMemberId: member.memberId,
      );
    }

    await deleteGroupLocal(groupId);
  }

  Future<void> deleteGroup(String groupId) async {
    if (!await isOwner(groupId, userId)) {
      throw GroupServiceException('Only the owner can delete the group');
    }

    final members = await getMembers(groupId);
    final keyRow = await DBHelper.getGroupKey(groupId);
    final keyVersion = keyRow?['keyVersion'] as int? ?? 1;

    await deleteGroupLocal(groupId);

    for (final member in members) {
      if (member.memberId == userId) continue;
      _controlChannel
          .sendMemberRemoved(
            groupId: groupId,
            removedMemberId: userId,
            keyVersion: keyVersion,
            targetMemberId: member.memberId,
          )
          .catchError((_) {});
    }
  }

  Future<void> setMemberRole({
    required String groupId,
    required String memberId,
    required GroupRole role,
  }) async {
    final actor = await _memberOf(groupId, userId);
    final target = await _memberOf(groupId, memberId);
    if (actor == null || target == null) {
      throw GroupServiceException('Member not in group');
    }
    if (role == GroupRole.admin) {
      if (!canPromoteToAdmin(actor: actor.role, target: target.role)) {
        throw GroupServiceException('Only the owner can promote admins');
      }
    } else if (role == GroupRole.member) {
      if (!canDemoteAdmin(actor: actor.role, target: target.role)) {
        throw GroupServiceException('Only the owner can demote admins');
      }
    } else {
      throw GroupServiceException('Invalid role');
    }
    await DBHelper.updateGroupMemberFields(
      groupId,
      memberId,
      {'role': groupRoleToWire(role)},
    );
    await _fanout(
      groupId,
      (targetId) => _controlChannel.sendRoleUpdate(
        groupId: groupId,
        memberId: memberId,
        role: groupRoleToWire(role),
        targetMemberId: targetId,
      ),
    );
  }

  Future<void> transferOwnership({
    required String groupId,
    required String newOwnerId,
  }) async {
    final actor = await _memberOf(groupId, userId);
    final target = await _memberOf(groupId, newOwnerId);
    if (actor == null || target == null) {
      throw GroupServiceException('Member not in group');
    }
    if (!canTransferOwnership(actor: actor.role, target: target.role)) {
      throw GroupServiceException('Only the owner can transfer ownership');
    }
    await DBHelper.updateGroupMemberFields(
      groupId,
      userId,
      {'role': groupRoleToWire(GroupRole.admin)},
    );
    await DBHelper.updateGroupMemberFields(
      groupId,
      newOwnerId,
      {'role': groupRoleToWire(GroupRole.owner)},
    );
    await DBHelper.updateGroupFields(groupId, {'createdBy': newOwnerId});
    await _fanout(
      groupId,
      (targetId) => _controlChannel.sendOwnerTransfer(
        groupId: groupId,
        newOwnerId: newOwnerId,
        targetMemberId: targetId,
      ),
    );
  }

  Future<void> setMemberMuted({
    required String groupId,
    required String memberId,
    required bool muted,
  }) async {
    final actor = await _memberOf(groupId, userId);
    final target = await _memberOf(groupId, memberId);
    if (actor == null || target == null) {
      throw GroupServiceException('Member not in group');
    }
    if (!canMuteOrKick(
      actor: actor.role,
      target: target.role,
      isSelf: memberId == userId,
    )) {
      throw GroupServiceException('Cannot mute this member');
    }
    await DBHelper.updateGroupMemberFields(
      groupId,
      memberId,
      {'muted': muted ? 1 : 0},
    );
    await _fanout(
      groupId,
      (targetId) => _controlChannel.sendMemberMute(
        groupId: groupId,
        memberId: memberId,
        muted: muted,
        targetMemberId: targetId,
      ),
    );
  }

  Future<void> setOnlyAdminsCanAdd({
    required String groupId,
    required bool onlyAdminsCanAdd,
  }) async {
    if (!await isAdmin(groupId, userId)) {
      throw GroupServiceException('Only admins can change this setting');
    }
    await DBHelper.updateGroupFields(groupId, {
      'onlyAdminsCanAdd': onlyAdminsCanAdd ? 1 : 0,
    });
    await _fanout(
      groupId,
      (targetId) => _controlChannel.sendPermissionsUpdate(
        groupId: groupId,
        onlyAdminsCanAdd: onlyAdminsCanAdd,
        targetMemberId: targetId,
      ),
    );
  }

  Future<void> deleteGroupLocal(String groupId, {bool notify = true}) async {
    await MessagesDb.deleteMessagesForGroup(groupId);
    await ConversationPreferencesService.instance.delete(groupId);
    await DBHelper.deleteGroup(groupId);
    invalidateGroupKeyCache(groupId);
    await GroupSenderIndexStore.resetForGroup(groupId);
    if (notify) {
      GroupMembershipNotifier.instance.notifyRemoved(groupId);
    }
  }

  /// Handle incoming control messages (from PrysmServer).
  ///
  /// Authenticates the sender before processing: the sender's identity is
  /// resolved from the local user store only (cache, never a Tor fetch —
  /// M2) and [encryptedPayload] must be a `control-wrap-2` envelope whose
  /// Ed25519 signature verifies against that identity's signing key.
  /// Unsigned legacy envelopes, forged signatures and senders whose identity
  /// is not in the local user store are dropped. For all types except
  /// invites the sender must additionally be a member of the target group.
  ///
  /// Returns true when the payload authenticated and was processed; false
  /// when it was dropped. Callers use the result to gate side effects (e.g.
  /// the sender-profile fetch in InboundMessageRouter) so unauthenticated
  /// traffic never reveals that the local user is online.
  Future<bool> handleIncomingControlMessage(
    String type,
    String encryptedPayload,
    String senderId,
  ) async {
    final senderKeys = await _resolveSenderIdentity(senderId);
    // Accepted policy (option 1, PR #128): a control message from a sender
    // whose identity is not in the local store is not processed. The
    // identity is required to *authenticate* it: decryptControlPayload
    // below verifies the control-wrap-2 signature against it, so without it
    // the payload can only be read unverified — which is exactly what must
    // not happen. Do not "fix" this by resolving the sender over the network
    // on cache-miss: that would reopen the M2 profile-fetch oracle (an
    // unauthenticated sender forcing GET /profile as an implicit delivery
    // receipt) before any signature check.
    //
    // What the user can choose (GroupInviteMode) is only what happens to an
    // *invite* afterwards: dropped outright, or held opaque and bounded for
    // the user to accept — never processed, never decrypted, and never a
    // reason to send anything.
    if (senderKeys == null) {
      if (type == groupInviteType &&
          _settings.groupInviteMode == GroupInviteMode.holdAsRequest) {
        // A store failure must not change the sender-visible outcome: on
        // this ingress a status difference is an oracle, so a broken store
        // (DB error, locked file) degrades to the plain drop, exactly like
        // a full one.
        try {
          final held = await GroupPendingInviteStore.hold(
            senderId: senderId,
            wire: encryptedPayload,
          );
          if (!held) {
            Logging.error(
              'Pending invite store full, dropping invite from '
              '${Logging.redactOnion(senderId)}',
              'GroupService',
            );
          }
        } catch (e) {
          Logging.error(
            'Pending invite store failed, dropping invite from '
            '${Logging.redactOnion(senderId)}: $e',
            'GroupService',
          );
        }
      }
      Logging.error(
        'Dropping $type from ${Logging.redactOnion(senderId)}: '
        'sender identity unresolvable',
        'GroupService',
      );
      return false;
    }

    final String plaintext;
    try {
      plaintext = await GroupCryptoV2.decryptControlPayload(
        encryptedPayload,
        keyManager.identity,
        senderKeys,
      );
    } catch (e) {
      Logging.error(
        'Dropping $type from ${Logging.redactOnion(senderId)}: '
        'control payload authentication failed: $e',
        'GroupService',
      );
      return false;
    }

    final data = jsonDecode(plaintext) as Map<String, dynamic>;

    if (type != groupInviteType) {
      final groupId = data['groupId'] as String?;
      if (groupId == null || !await DBHelper.isGroupMember(groupId, senderId)) {
        Logging.error(
          'Dropping $type from ${Logging.redactOnion(senderId)} for '
          'group $groupId',
          'GroupService',
        );
        return false;
      }
    }

    switch (type) {
      case groupInviteType:
        await _handleInvite(data, senderId);
        break;
      case groupKeyRotateType:
        await _handleKeyRotate(data);
        break;
      case groupMemberRemovedType:
        await _handleMemberRemoved(data, senderId);
        break;
      case groupProfileUpdateType:
        await _handleProfileUpdate(data);
        break;
      case groupDisappearingTimerType:
        await _handleDisappearingTimer(data);
        break;
      case groupRoleUpdateType:
        await _handleRoleUpdate(data, senderId);
        break;
      case groupOwnerTransferType:
        await _handleOwnerTransfer(data, senderId);
        break;
      case groupMemberMuteType:
        await _handleMemberMute(data, senderId);
        break;
      case groupPermissionsUpdateType:
        await _handlePermissionsUpdate(data, senderId);
        break;
    }
    return true;
  }

  /// Resolves the sender's public identity from the local user store only.
  ///
  /// M2 (security): never a Tor fetch. The control payload's signature is
  /// only verified against the identity held here, and resolving over the
  /// network on cache-miss would let an unknown peer force an outbound
  /// GET /profile — an implicit delivery receipt — before any signature
  /// check. Legitimate members are in the user store, so the good path is
  /// unaffected; unknown senders are dropped by the caller.
  Future<IdentityPublicKeys?> _resolveSenderIdentity(String senderId) async {
    return loadPeerIdentityFromDb(keyManager, senderId);
  }

  Future<void> _handleDisappearingTimer(Map<String, dynamic> data) async {
    final groupId = data['groupId'] as String;
    final raw = data['timerSeconds'];
    int? timerSeconds;
    if (raw is int && raw > 0) timerSeconds = raw;
    final updatedAt = data['updatedAt'] as int? ??
        DateTime.now().millisecondsSinceEpoch;
    final updatedBy = data['updatedBy'] as String?;
    await DisappearingTimerService.applyInboundGroup(
      groupId: groupId,
      payload: DisappearingTimerPayload(
        timerSeconds: timerSeconds,
        updatedAt: updatedAt,
        updatedBy: updatedBy,
      ),
      localUserId: userId,
    );
  }

  Future<void> _handleInvite(Map<String, dynamic> data, String senderId) async {
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
      Logging.error('Ignoring stale group invite for $groupId (v$keyVersion < v$localKeyVersion)', 'GroupService');
      return;
    }

    final inviteMemberIds = members.map((m) => m['id'] as String).toSet();
    if (existing != null && !inviteMemberIds.contains(userId)) {
      Logging.error('Ignoring group invite for $groupId — local user not in roster', 'GroupService');
      return;
    }

    final groupKey = await GroupCryptoV2.decryptGroupKey(
      encryptedGroupKey,
      keyManager.identity,
    );
    final encryptedForSelf = await GroupCryptoV2.encryptGroupKeyForStorage(
      groupKey,
      keyManager.identity,
    );
    final now = DateTime.now().millisecondsSinceEpoch;

    final avatarBase64 = data['avatarBase64'] as String?;
    if (existing == null) {
      await DBHelper.insertGroup({
        'id': groupId,
        'name': name,
        'avatarBase64': avatarBase64,
        'createdBy': createdBy,
        'createdAt': now,
        'onlyAdminsCanAdd': (data['onlyAdminsCanAdd'] ?? 1) == 1 ? 1 : 0,
      });
    } else if (avatarBase64 != null) {
      await DBHelper.updateGroupFields(groupId, {
        'name': name,
        'avatarBase64': avatarBase64,
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

    if (!isNewToGroup) {
      final sender = await _memberOf(groupId, senderId);
      final onlyAdmins =
          ((await DBHelper.getGroupById(groupId))?['onlyAdminsCanAdd'] ?? 1) == 1;
      final senderCanAdd = sender != null &&
          canAddMembers(actor: sender.role, onlyAdminsCanAdd: onlyAdmins);
      for (final m in members) {
        final memberId = m['id'] as String;
        if (localMemberIds.contains(memberId)) continue;
        if (!senderCanAdd) continue;
        await DBHelper.addGroupMember({
          'groupId': groupId,
          'memberId': memberId,
          'role': 'member',
          'joinedAt': now,
          'muted': 0,
        });
      }
      if (keyVersion == localKeyVersion &&
          sender != null &&
          groupRoleIsModerator(sender.role)) {
        for (final local in localMembers) {
          if (!inviteMemberIds.contains(local.memberId)) {
            await DBHelper.removeGroupMember(groupId, local.memberId);
          }
        }
      }
      return;
    }

    for (final m in members) {
      final memberId = m['id'] as String;
      final mutedRaw = m['muted'];
      final muted = mutedRaw == 1 || mutedRaw == '1' || mutedRaw == true;
      await DBHelper.addGroupMember({
        'groupId': groupId,
        'memberId': memberId,
        'role': m['role'] as String? ?? 'member',
        'joinedAt': now,
        'muted': muted ? 1 : 0,
      });
    }

    if (isNewToGroup) {
      await MessagesDb.deleteGroupMessagesBefore(groupId, now);
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
      Logging.error('Ignoring stale key rotate for $groupId (v$keyVersion <= v$localKeyVersion)', 'GroupService');
      return;
    }

    final groupKey = await GroupCryptoV2.decryptGroupKey(
      encryptedGroupKey,
      keyManager.identity,
    );
    final encryptedForSelf = await GroupCryptoV2.encryptGroupKeyForStorage(
      groupKey,
      keyManager.identity,
    );
    await DBHelper.upsertGroupKey(
      groupId: groupId,
      encryptedKey: encryptedForSelf,
      keyVersion: keyVersion,
    );
    invalidateGroupKeyCache(groupId);
    await GroupSenderIndexStore.resetForGroup(groupId);

    if (removedMemberId != null && removedMemberId == userId) {
      await deleteGroupLocal(groupId);
    }
  }

  Future<void> _handleMemberRemoved(
    Map<String, dynamic> data,
    String senderId,
  ) async {
    final groupId = data['groupId'] as String;
    final removedMemberId = data['removedMemberId'] as String;

    if (removedMemberId == userId) {
      await deleteGroupLocal(groupId);
      return;
    }

    if (removedMemberId != senderId) {
      final sender = await _memberOf(groupId, senderId);
      final target = await _memberOf(groupId, removedMemberId);
      if (sender == null ||
          target == null ||
          !canMuteOrKick(
            actor: sender.role,
            target: target.role,
            isSelf: false,
          )) {
        return;
      }
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

    await DBHelper.updateGroupFields(groupId, {
      'name': ?name,
      'avatarBase64': ?avatarBase64,
    });
  }

  Future<void> _handleRoleUpdate(
    Map<String, dynamic> data,
    String senderId,
  ) async {
    final groupId = data['groupId'] as String;
    final memberId = data['memberId'] as String?;
    final role = groupRoleFromWire(data['role'] as String?);
    if (memberId == null) return;
    final sender = await _memberOf(groupId, senderId);
    final target = await _memberOf(groupId, memberId);
    if (sender == null || target == null) return;
    if (role == GroupRole.admin &&
        !canPromoteToAdmin(actor: sender.role, target: target.role)) {
      return;
    }
    if (role == GroupRole.member &&
        !canDemoteAdmin(actor: sender.role, target: target.role)) {
      return;
    }
    if (role == GroupRole.owner) return;
    await DBHelper.updateGroupMemberFields(
      groupId,
      memberId,
      {'role': groupRoleToWire(role)},
    );
  }

  Future<void> _handleOwnerTransfer(
    Map<String, dynamic> data,
    String senderId,
  ) async {
    final groupId = data['groupId'] as String;
    final newOwnerId = data['newOwnerId'] as String?;
    if (newOwnerId == null) return;
    final sender = await _memberOf(groupId, senderId);
    final target = await _memberOf(groupId, newOwnerId);
    if (sender == null || target == null) return;
    if (!canTransferOwnership(actor: sender.role, target: target.role)) return;
    await DBHelper.updateGroupMemberFields(
      groupId,
      senderId,
      {'role': groupRoleToWire(GroupRole.admin)},
    );
    await DBHelper.updateGroupMemberFields(
      groupId,
      newOwnerId,
      {'role': groupRoleToWire(GroupRole.owner)},
    );
    await DBHelper.updateGroupFields(groupId, {'createdBy': newOwnerId});
  }

  Future<void> _handleMemberMute(
    Map<String, dynamic> data,
    String senderId,
  ) async {
    final groupId = data['groupId'] as String;
    final memberId = data['memberId'] as String?;
    if (memberId == null) return;
    final sender = await _memberOf(groupId, senderId);
    final target = await _memberOf(groupId, memberId);
    if (sender == null || target == null) return;
    if (!canMuteOrKick(
      actor: sender.role,
      target: target.role,
      isSelf: memberId == senderId,
    )) {
      return;
    }
    final muted = data['muted'] == 1 || data['muted'] == true;
    await DBHelper.updateGroupMemberFields(
      groupId,
      memberId,
      {'muted': muted ? 1 : 0},
    );
  }

  Future<void> _handlePermissionsUpdate(
    Map<String, dynamic> data,
    String senderId,
  ) async {
    final groupId = data['groupId'] as String;
    final sender = await _memberOf(groupId, senderId);
    if (sender == null || !groupRoleIsModerator(sender.role)) return;
    final onlyAdmins = data['onlyAdminsCanAdd'] == 1 ||
        data['onlyAdminsCanAdd'] == true;
    await DBHelper.updateGroupFields(groupId, {
      'onlyAdminsCanAdd': onlyAdmins ? 1 : 0,
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
}
