import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/models/group.dart';
import 'package:prysm/util/group_moderation_policy.dart';

void main() {
  test('only the owner manages roles, transfers, and deletes the group', () {
    expect(canManageRoles(GroupRole.owner), isTrue);
    expect(canManageRoles(GroupRole.admin), isFalse);
    expect(canDeleteGroup(GroupRole.owner), isTrue);
    expect(canDeleteGroup(GroupRole.admin), isFalse);
    expect(canLeaveWithoutTransfer(GroupRole.owner), isFalse);
    expect(canLeaveWithoutTransfer(GroupRole.admin), isTrue);
    expect(canLeaveWithoutTransfer(GroupRole.member), isTrue);
    expect(
      canPromoteToAdmin(actor: GroupRole.owner, target: GroupRole.member),
      isTrue,
    );
    expect(
      canPromoteToAdmin(actor: GroupRole.admin, target: GroupRole.member),
      isFalse,
    );
    expect(
      canDemoteAdmin(actor: GroupRole.owner, target: GroupRole.admin),
      isTrue,
    );
    expect(
      canTransferOwnership(actor: GroupRole.owner, target: GroupRole.admin),
      isTrue,
    );
    expect(
      canTransferOwnership(actor: GroupRole.owner, target: GroupRole.owner),
      isFalse,
    );
  });

  test('mute and kick follow the owner/admin target matrix', () {
    expect(
      canMuteOrKick(
        actor: GroupRole.owner,
        target: GroupRole.admin,
        isSelf: false,
      ),
      isTrue,
    );
    expect(
      canMuteOrKick(
        actor: GroupRole.owner,
        target: GroupRole.owner,
        isSelf: false,
      ),
      isFalse,
    );
    expect(
      canMuteOrKick(
        actor: GroupRole.admin,
        target: GroupRole.member,
        isSelf: false,
      ),
      isTrue,
    );
    expect(
      canMuteOrKick(
        actor: GroupRole.admin,
        target: GroupRole.admin,
        isSelf: false,
      ),
      isFalse,
    );
    expect(
      canMuteOrKick(
        actor: GroupRole.admin,
        target: GroupRole.owner,
        isSelf: false,
      ),
      isFalse,
    );
    expect(
      canMuteOrKick(
        actor: GroupRole.member,
        target: GroupRole.member,
        isSelf: false,
      ),
      isFalse,
    );
    expect(
      canMuteOrKick(
        actor: GroupRole.owner,
        target: GroupRole.member,
        isSelf: true,
      ),
      isFalse,
    );
  });

  test('add-member lock and send/delete matrices', () {
    expect(
      canAddMembers(actor: GroupRole.member, onlyAdminsCanAdd: true),
      isFalse,
    );
    expect(
      canAddMembers(actor: GroupRole.member, onlyAdminsCanAdd: false),
      isTrue,
    );
    expect(
      canAddMembers(actor: GroupRole.admin, onlyAdminsCanAdd: true),
      isTrue,
    );
    expect(
      canModerationDelete(actor: GroupRole.owner, author: GroupRole.admin),
      isTrue,
    );
    expect(
      canModerationDelete(actor: GroupRole.admin, author: GroupRole.member),
      isTrue,
    );
    expect(
      canModerationDelete(actor: GroupRole.admin, author: GroupRole.owner),
      isFalse,
    );
    expect(canSendChat(muted: false), isTrue);
    expect(canSendChat(muted: true), isFalse);
  });

  test('any member can start a group call; muted members listen only', () {
    expect(canStartGroupCall(GroupRole.owner), isTrue);
    expect(canStartGroupCall(GroupRole.admin), isTrue);
    expect(canStartGroupCall(GroupRole.member), isTrue);
    expect(canSpeakInGroupCall(muted: false), isTrue);
    expect(canSpeakInGroupCall(muted: true), isFalse);
  });
}
