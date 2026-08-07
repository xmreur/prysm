import 'package:prysm/constants/group_constants.dart';
import 'package:prysm/models/group_invite_mode.dart';
import 'package:prysm/services/group_service.dart';
import 'package:prysm/services/settings_service.dart';
import 'package:prysm/util/group_pending_invite_store.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/logging.dart';
import 'package:prysm/util/peer_identity_loader.dart';

/// Replays a held first-contact invite once its sender's identity is in the
/// local user store.
///
/// Promotion never bypasses authentication: the held envelope goes through
/// [GroupService.handleIncomingControlMessage], the same path the message
/// would have taken had the sender been known when it arrived. The row is
/// removed either way — an envelope that fails to authenticate is garbage,
/// and keeping it would let a failed attempt be retried forever.
///
/// Known limitation, deliberately not fixed here because it is not this
/// class's to fix: an invite is a point-in-time snapshot of a group's roster
/// and key version, and `_handleInvite`'s staleness guards read only local
/// state (`group_service.dart:626-639`). So a snapshot applied late can
/// re-create a group the user has since left — `deleteGroupLocal` removes the
/// `group_keys` row, which sets `localKeyVersion` back to 0 and disarms the
/// version guard — and can drop members who joined after it was taken, since
/// adding a member does not rotate the key. This is a pre-existing property
/// of the live path: a queued invite envelope re-delivered by the transport
/// after the user left does exactly the same thing. Promotion does not widen
/// it beyond `GroupPendingInviteStore.retention`, which bounds how stale a
/// replayed snapshot can be.
class GroupInvitePromoter {
  GroupInvitePromoter({
    required this.userId,
    required this.keyManager,
    GroupService? groupService,
  }) : _groupService = groupService ??
            GroupService(userId: userId, keyManager: keyManager);

  final String userId;
  final KeyManager keyManager;
  final GroupService _groupService;

  Future<bool> promote(String senderId) async {
    final wire = await GroupPendingInviteStore.take(senderId);
    if (wire == null) return false;
    try {
      return await _groupService.handleIncomingControlMessage(
        groupInviteType,
        wire,
        senderId,
      );
    } catch (e) {
      Logging.error(
        'Promoting the held invite from ${Logging.redactOnion(senderId)} '
        'failed: $e',
        'GroupInvitePromoter',
      );
      return false;
    }
  }

  /// Promotes every pending invite whose sender is now locally known.
  /// Returns how many were applied.
  ///
  /// A no-op while the mode is `contactsOnly`: that mode promises nothing is
  /// stored and nothing is applied, and any rows still present (e.g. held
  /// before the mode changed) must not be promoted behind the user's back.
  Future<int> promoteResolvable() async {
    if (SettingsService().groupInviteMode == GroupInviteMode.contactsOnly) {
      return 0;
    }
    final rows = await GroupPendingInviteStore.pending();
    var promoted = 0;
    for (final row in rows) {
      final senderId = row['senderId'] as String;
      if (await loadPeerIdentityFromDb(keyManager, senderId) == null) continue;
      if (await promote(senderId)) promoted++;
    }
    return promoted;
  }
}
