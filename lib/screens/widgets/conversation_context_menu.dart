import 'package:flutter/widgets.dart';
import 'package:prysm/ui/core/prysm_icons.dart';
import 'package:prysm/models/conversation.dart';
import 'package:prysm/models/conversation_preferences.dart';
import 'package:prysm/util/desktop_platform.dart';
import 'package:prysm/ui/core/prysm_list_row.dart';
import 'package:prysm/ui/core/prysm_divider.dart';

Future<void> showConversationContextMenu({
  required BuildContext context,
  required Offset position,
  required Conversation conversation,
  required ConversationPreferences? preferences,
  required bool viewingArchived,
  required bool canOpenDetached,
  bool showPinArchive = true,
  required Future<void> Function() onOpenDetached,
  Future<void> Function()? onPin,
  Future<void> Function()? onUnpin,
  Future<void> Function()? onArchive,
  Future<void> Function()? onUnarchive,
}) async {
  if (!isDesktopPlatform) {
    return;
  }

  final isPinned = preferences?.isPinned ?? false;
  final isArchived = preferences?.isArchived ?? false;

  final value = await showPrysmSheet<String>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (canOpenDetached)
            PrysmListRow(
              leading: const Icon(PrysmIcons.openInNew),
              title: 'Open in a separate window',
              onTap: () => Navigator.pop(ctx, 'open_detached'),
            ),
          if (canOpenDetached) const PrysmDivider(),
          if (showPinArchive && !viewingArchived && !isArchived)
            PrysmListRow(
              leading: Icon(
                isPinned ? PrysmIcons.pushPinOutlined : PrysmIcons.pushPin,
              ),
              title: isPinned ? 'Unpin chat' : 'Pin chat',
              onTap: () => Navigator.pop(ctx, 'pin'),
            ),
          if (showPinArchive)
            PrysmListRow(
              leading: const Icon(PrysmIcons.archive),
              title: viewingArchived || isArchived
                  ? 'Unarchive chat'
                  : 'Archive chat',
              onTap: () => Navigator.pop(ctx, 'archive'),
            ),
        ],
      ),
    ),
  );

  switch (value) {
    case 'open_detached':
      await onOpenDetached();
    case 'pin':
      if (isPinned) {
        await onUnpin?.call();
      } else {
        await onPin?.call();
      }
    case 'archive':
      if (viewingArchived || isArchived) {
        await onUnarchive?.call();
      } else {
        await onArchive?.call();
      }
  }
}
