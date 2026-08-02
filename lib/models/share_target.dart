import 'package:prysm/models/detached_chat_launch.dart';

/// Destination chosen in the share-target chat picker.
class ShareTarget {
  const ShareTarget({
    required this.kind,
    required this.conversationId,
    required this.displayName,
  });

  final DetachedChatKind kind;
  final String conversationId;
  final String displayName;
}
