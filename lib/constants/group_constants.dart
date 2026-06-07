/// Maximum number of participants in a group (including yourself).
const int maxGroupMembers = 5;

// Control message types (RSA-encrypted payload in `message` field)
const String groupInviteType = 'group_invite';
const String groupKeyRotateType = 'group_key_rotate';
const String groupMemberRemovedType = 'group_member_removed';
const String groupProfileUpdateType = 'group_profile_update';
const String groupHistoryRelayType = 'group_history_relay';

// Group chat message types (AES group-key encrypted payload)
const String groupTextType = 'group_text';
const String groupImageType = 'group_image';
const String groupFileType = 'group_file';
const String groupAudioType = 'group_audio';

// Reaction side-channel types (small encrypted JSON in `message` field)
const String reactionType = 'reaction';
const String groupReactionType = 'group_reaction';

const Set<String> groupControlTypes = {
  groupInviteType,
  groupKeyRotateType,
  groupMemberRemovedType,
  groupProfileUpdateType,
};

const Set<String> groupMessageTypes = {
  groupTextType,
  groupImageType,
  groupFileType,
  groupAudioType,
};

const Set<String> reactionTypes = {reactionType, groupReactionType};

bool isGroupControlType(String type) => groupControlTypes.contains(type);
bool isGroupMessageType(String type) => groupMessageTypes.contains(type);
bool isReactionType(String type) => reactionTypes.contains(type);

/// Deterministic wire id for a reaction event (dedupe / pending queue).
String reactionEventId({
  required String targetMessageId,
  required String reactorId,
}) =>
    '$targetMessageId::$reactorId';
