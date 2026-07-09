import 'package:flutter/widgets.dart';
import 'package:prysm/ui/core/prysm_icons.dart';
import 'package:prysm/models/conversation.dart';
import 'package:prysm/models/conversation_preferences.dart';
import 'package:prysm/ui/core/prysm_list_row.dart';
import 'package:prysm/theme/prysm_style_scope.dart';

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

  return showPrysmSheet<void>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: Text(
              conversation.displayName,
              style: ctx.prysmStyle.titleStyle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (!viewingArchived && !isArchived)
            PrysmListRow(
              leading: Icon(
                isPinned ? PrysmIcons.pushPinOutlined : PrysmIcons.pushPin,
              ),
              title: isPinned ? 'Unpin chat' : 'Pin chat',
              onTap: () async {
                Navigator.pop(ctx);
                if (isPinned) {
                  await onUnpin();
                } else {
                  await onPin();
                }
              },
            ),
          PrysmListRow(
            leading: const Icon(PrysmIcons.archive),
            title: viewingArchived || isArchived
                ? 'Unarchive chat'
                : 'Archive chat',
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
