import 'package:prysm/models/contact.dart';
import 'package:prysm/models/group.dart';

sealed class Conversation {
  int? get lastMessageTimestamp;

  String get id;
  String get displayName;
}

class DirectConversation extends Conversation {
  final Contact contact;

  DirectConversation(this.contact);

  @override
  int? get lastMessageTimestamp => contact.lastMessageTimestamp;

  @override
  String get id => contact.id;

  @override
  String get displayName => contact.displayName;
}

class GroupConversation extends Conversation {
  final Group group;

  GroupConversation(this.group);

  @override
  int? get lastMessageTimestamp => group.lastMessageTimestamp;

  @override
  String get id => group.id;

  @override
  String get displayName => group.name;
}

/// Local notes-to-self chat (not P2P).
class SelfConversation extends Conversation {
  SelfConversation(this._lastTimestamp);

  static const conversationId = '__self__';

  final int? _lastTimestamp;

  @override
  String get id => conversationId;

  @override
  String get displayName => 'Chat with myself';

  @override
  int? get lastMessageTimestamp => _lastTimestamp;
}
