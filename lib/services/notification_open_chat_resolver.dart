import 'package:prysm/models/contact.dart';
import 'package:prysm/models/group.dart';
import 'package:prysm/util/db_helper.dart';

/// Resolves notification targets to chat models from memory or SQLite.
class NotificationOpenChatResolver {
  static Contact? findContactInMemory(
    List<Contact> contacts,
    String senderId,
  ) {
    for (final contact in contacts) {
      if (contact.id == senderId) return contact;
    }
    return null;
  }

  static Group? findGroupInMemory(List<Group> groups, String groupId) {
    for (final group in groups) {
      if (group.id == groupId) return group;
    }
    return null;
  }

  static Future<Contact?> resolveContact({
    required List<Contact> contacts,
    required String senderId,
  }) async {
    final inMemory = findContactInMemory(contacts, senderId);
    if (inMemory != null) return inMemory;

    final row = await DBHelper.getUserById(senderId);
    if (row == null) return null;

    return Contact(
      id: row['id'] as String,
      name: row['name'] as String? ?? 'Unknown contact',
      avatarUrl: '',
      avatarBase64: row['avatarBase64'] as String?,
      customName: row['customName'] as String?,
      identityJson: (row['identityJson'] as String?) ?? (row['publicKeyPem'] as String?) ?? '',
    );
  }

  static Future<Group?> resolveGroup({
    required List<Group> groups,
    required String groupId,
  }) async {
    final inMemory = findGroupInMemory(groups, groupId);
    if (inMemory != null) return inMemory;

    final row = await DBHelper.getGroupById(groupId);
    if (row == null) return null;

    return Group.fromMap(row);
  }
}
