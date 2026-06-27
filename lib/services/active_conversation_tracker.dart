/// Tracks which conversation is currently open in the UI.
class ActiveConversationTracker {
  ActiveConversationTracker._();

  static final ActiveConversationTracker instance =
      ActiveConversationTracker._();

  String? peerId;
  String? groupId;

  void setDirect(String peerOnion) {
    peerId = peerOnion;
    groupId = null;
  }

  void setGroup(String groupIdValue) {
    groupId = groupIdValue;
    peerId = null;
  }

  void clear() {
    peerId = null;
    groupId = null;
  }

  bool matchesInbound({
    String? inboundGroupId,
    required String senderId,
  }) {
    if (inboundGroupId != null && inboundGroupId.isNotEmpty) {
      return groupId == inboundGroupId;
    }
    return peerId == senderId;
  }
}
