import 'package:prysm/models/group.dart';

bool canManageRoles(GroupRole actor) => actor == GroupRole.owner;

bool canDeleteGroup(GroupRole actor) => actor == GroupRole.owner;

bool canLeaveWithoutTransfer(GroupRole actor) => actor != GroupRole.owner;

bool canAddMembers({
  required GroupRole actor,
  required bool onlyAdminsCanAdd,
}) {
  if (groupRoleIsModerator(actor)) return true;
  return !onlyAdminsCanAdd;
}

bool canMuteOrKick({
  required GroupRole actor,
  required GroupRole target,
  required bool isSelf,
}) {
  if (isSelf) return false;
  if (actor == GroupRole.owner) return target != GroupRole.owner;
  if (actor == GroupRole.admin) return target == GroupRole.member;
  return false;
}

bool canPromoteToAdmin({
  required GroupRole actor,
  required GroupRole target,
}) =>
    actor == GroupRole.owner && target == GroupRole.member;

bool canDemoteAdmin({
  required GroupRole actor,
  required GroupRole target,
}) =>
    actor == GroupRole.owner && target == GroupRole.admin;

bool canTransferOwnership({
  required GroupRole actor,
  required GroupRole target,
}) =>
    actor == GroupRole.owner && target != GroupRole.owner;

bool canModerationDelete({
  required GroupRole actor,
  required GroupRole author,
}) {
  if (actor == GroupRole.owner) return true;
  if (actor == GroupRole.admin) return author == GroupRole.member;
  return false;
}

bool canSendChat({required bool muted}) => !muted;
