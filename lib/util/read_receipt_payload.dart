import 'dart:convert';

/// Plaintext read receipt payload (encrypted before sending over Tor).
class ReadReceiptPayload {
  final String targetMessageId;
  final String readerId;
  final String? groupId;
  final int timestamp;

  const ReadReceiptPayload({
    required this.targetMessageId,
    required this.readerId,
    this.groupId,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() => {
        'targetMessageId': targetMessageId,
        'readerId': readerId,
        if (groupId != null) 'groupId': groupId,
        'timestamp': timestamp,
      };

  factory ReadReceiptPayload.fromJson(Map<String, dynamic> json) {
    return ReadReceiptPayload(
      targetMessageId: json['targetMessageId'] as String,
      readerId: json['readerId'] as String,
      groupId: json['groupId'] as String?,
      timestamp: json['timestamp'] as int,
    );
  }

  String encode() => jsonEncode(toJson());

  static ReadReceiptPayload decode(String plaintext) {
    return ReadReceiptPayload.fromJson(
      jsonDecode(plaintext) as Map<String, dynamic>,
    );
  }
}
