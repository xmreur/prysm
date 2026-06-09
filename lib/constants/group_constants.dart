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

const String messageModifyType = 'message_modify';
const String groupMessageModifyType = 'group_message_modify';

const String readReceiptType = 'read_receipt';
const String groupReadReceiptType = 'group_read_receipt';
const String readWaterlineType = 'read_waterline';
const String groupReadWaterlineType = 'group_read_waterline';

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

const Set<String> messageModifyTypes = {
  messageModifyType,
  groupMessageModifyType,
};

const Set<String> readReceiptTypes = {
  readReceiptType,
  groupReadReceiptType,
  readWaterlineType,
  groupReadWaterlineType,
};

bool isGroupControlType(String type) => groupControlTypes.contains(type);
bool isGroupMessageType(String type) => groupMessageTypes.contains(type);
bool isReactionType(String type) => reactionTypes.contains(type);
bool isMessageModifyType(String type) => messageModifyTypes.contains(type);
bool isReadReceiptType(String type) => readReceiptTypes.contains(type);

/// Deterministic wire id for a reaction event (dedupe / pending queue).
String reactionEventId({
  required String targetMessageId,
  required String reactorId,
}) =>
    '$targetMessageId::$reactorId';

/// Deterministic wire id for a read receipt event (dedupe / pending queue).
String readReceiptEventId({
  required String targetMessageId,
  required String readerId,
}) =>
    '$targetMessageId::$readerId';

/// One pending row per peer conversation for read waterlines.
String readWaterlineEventId({
  required String readerId,
  required String peerId,
  String? groupId,
}) =>
    groupId != null
        ? 'read_waterline::$readerId::$groupId'
        : 'read_waterline::$readerId::$peerId';
