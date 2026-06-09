import 'dart:convert';

/// Plaintext read receipt / waterline payload (encrypted before sending over Tor).
class ReadReceiptPayload {
  final String targetMessageId;
  final String readerId;
  final String? groupId;
  final int timestamp;
  final int? readUpToTimestamp;

  const ReadReceiptPayload({
    required this.targetMessageId,
    required this.readerId,
    this.groupId,
    required this.timestamp,
    this.readUpToTimestamp,
  });

  int get effectiveReadUpToTimestamp => readUpToTimestamp ?? timestamp;

  bool get isWaterline => readUpToTimestamp != null;

  Map<String, dynamic> toJson() => {
        'targetMessageId': targetMessageId,
        'latestMessageId': targetMessageId,
        'readerId': readerId,
        if (groupId != null) 'groupId': groupId,
        'timestamp': timestamp,
        if (readUpToTimestamp != null) 'readUpToTimestamp': readUpToTimestamp,
      };

  factory ReadReceiptPayload.fromJson(Map<String, dynamic> json) {
    final latest = (json['latestMessageId'] ?? json['targetMessageId']) as String;
    return ReadReceiptPayload(
      targetMessageId: latest,
      readerId: json['readerId'] as String,
      groupId: json['groupId'] as String?,
      timestamp: json['timestamp'] as int,
      readUpToTimestamp: json['readUpToTimestamp'] as int?,
    );
  }

  String encode() => jsonEncode(toJson());

  static ReadReceiptPayload decode(String plaintext) {
    return ReadReceiptPayload.fromJson(
      jsonDecode(plaintext) as Map<String, dynamic>,
    );
  }
}
