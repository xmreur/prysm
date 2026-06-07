import 'dart:convert';

/// Plaintext edit/delete payload (encrypted before sending over Tor).
class MessageModifyPayload {
  final String targetMessageId;
  final String action;
  final String? encryptedBody;
  final int modifiedAt;

  const MessageModifyPayload({
    required this.targetMessageId,
    required this.action,
    this.encryptedBody,
    required this.modifiedAt,
  });

  bool get isEdit => action == 'edit';
  bool get isDelete => action == 'delete';

  Map<String, dynamic> toJson() => {
        'targetMessageId': targetMessageId,
        'action': action,
        if (encryptedBody != null) 'encryptedBody': encryptedBody,
        'modifiedAt': modifiedAt,
      };

  factory MessageModifyPayload.fromJson(Map<String, dynamic> json) {
    return MessageModifyPayload(
      targetMessageId: json['targetMessageId'] as String,
      action: json['action'] as String,
      encryptedBody: json['encryptedBody'] as String?,
      modifiedAt: json['modifiedAt'] as int,
    );
  }

  String encode() => jsonEncode(toJson());

  static MessageModifyPayload decode(String plaintext) {
    return MessageModifyPayload.fromJson(
      jsonDecode(plaintext) as Map<String, dynamic>,
    );
  }
}
