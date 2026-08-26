import 'package:prysm/models/contact.dart';
import 'package:prysm/models/conversation.dart';
import 'package:prysm/models/conversation_preferences.dart';
import 'package:prysm/models/group.dart';
import 'package:prysm/services/block_service.dart';
import 'package:prysm/services/conversation_preferences_service.dart';
import 'package:prysm/util/db_helper.dart';

/// Conversations that can receive a share or forward.
class ShareableConversations {
  ShareableConversations._();

  static List<Conversation> filter({
    required List<Conversation> conversations,
    required Map<String, ConversationPreferences> prefs,
  }) {
    return conversations.where((conversation) {
      if (conversation is DirectConversation &&
          BlockService.instance.isBlocked(conversation.id)) {
        return false;
      }
      return !(prefs[conversation.id]?.isArchived ?? false);
    }).toList();
  }

  static Future<List<Conversation>> loadFromDb({
    required String localUserId,
  }) async {
    final users = await DBHelper.getUsers();
    final groups = await DBHelper.getGroups();
    final prefs = await ConversationPreferencesService.instance.getAll();
    final conversations = <Conversation>[
      ...users
          .where((map) => map['id'] != localUserId)
          .map((map) => DirectConversation(Contact.fromMap(map))),
      ...groups.map((map) => GroupConversation(Group.fromMap(map))),
    ];
    return filter(conversations: conversations, prefs: prefs);
  }
}
