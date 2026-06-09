/// Result of marking inbound messages read locally (one waterline per batch).
class ReadWaterlineMark {
  final String latestMessageId;
  final int readUpToTimestamp;
  final String? groupId;

  const ReadWaterlineMark({
    required this.latestMessageId,
    required this.readUpToTimestamp,
    this.groupId,
  });
}
