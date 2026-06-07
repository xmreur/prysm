import 'dart:convert';

/// Plaintext reaction payload (encrypted before sending over Tor).
class ReactionPayload {
  final String targetMessageId;
  final String emoji;
  final String action;
  final int timestamp;

  const ReactionPayload({
    required this.targetMessageId,
    required this.emoji,
    required this.action,
    required this.timestamp,
  });

  bool get isAdd => action == 'add';
  bool get isRemove => action == 'remove';

  Map<String, dynamic> toJson() => {
        'targetMessageId': targetMessageId,
        'emoji': emoji,
        'action': action,
        'timestamp': timestamp,
      };

  factory ReactionPayload.fromJson(Map<String, dynamic> json) {
    return ReactionPayload(
      targetMessageId: json['targetMessageId'] as String,
      emoji: json['emoji'] as String,
      action: json['action'] as String,
      timestamp: json['timestamp'] as int,
    );
  }

  String encode() => jsonEncode(toJson());

  static ReactionPayload decode(String plaintext) {
    return ReactionPayload.fromJson(
      jsonDecode(plaintext) as Map<String, dynamic>,
    );
  }
}

/// Build flutter_chat_core reactions map from DB rows.
Map<String, List<String>> aggregateReactions(
  List<Map<String, dynamic>> rows,
) {
  final map = <String, List<String>>{};
  for (final row in rows) {
    final emoji = row['emoji'] as String;
    final reactorId = row['reactorId'] as String;
    map.putIfAbsent(emoji, () => []).add(reactorId);
  }
  return map;
}
