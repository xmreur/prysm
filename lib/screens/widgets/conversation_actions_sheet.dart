import 'package:flutter/material.dart';
import 'package:prysm/models/conversation.dart';
import 'package:prysm/models/conversation_preferences.dart';

Future<void> showConversationActionsSheet({
  required BuildContext context,
  required Conversation conversation,
  required ConversationPreferences? preferences,
  required bool viewingArchived,
  required Future<void> Function() onPin,
  required Future<void> Function() onUnpin,
  required Future<void> Function() onArchive,
  required Future<void> Function() onUnarchive,
}) {
  final isPinned = preferences?.isPinned ?? false;
  final isArchived = preferences?.isArchived ?? false;

  return showModalBottomSheet<void>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: Text(
              conversation.displayName,
              style: Theme.of(ctx).textTheme.titleMedium,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (!viewingArchived && !isArchived)
            ListTile(
              leading: Icon(
                isPinned ? Icons.push_pin_outlined : Icons.push_pin,
              ),
              title: Text(isPinned ? 'Unpin chat' : 'Pin chat'),
              onTap: () async {
                Navigator.pop(ctx);
                if (isPinned) {
                  await onUnpin();
                } else {
                  await onPin();
                }
              },
            ),
          ListTile(
            leading: const Icon(Icons.archive_outlined),
            title: Text(
              viewingArchived || isArchived ? 'Unarchive chat' : 'Archive chat',
            ),
            onTap: () async {
              Navigator.pop(ctx);
              if (viewingArchived || isArchived) {
                await onUnarchive();
              } else {
                await onArchive();
              }
            },
          ),
        ],
      ),
    ),
  );
}
