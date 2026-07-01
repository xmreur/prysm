import 'package:flutter/material.dart';
import 'package:prysm/models/conversation.dart';
import 'package:prysm/models/conversation_preferences.dart';
import 'package:prysm/util/desktop_platform.dart';

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

  final value = await showMenu<String>(
    context: context,
    position: RelativeRect.fromLTRB(
      position.dx,
      position.dy,
      position.dx,
      position.dy,
    ),
    items: [
      if (canOpenDetached)
        const PopupMenuItem<String>(
          value: 'open_detached',
          child: ListTile(
            leading: Icon(Icons.open_in_new),
            title: Text('Open in a separate window'),
            contentPadding: EdgeInsets.zero,
            dense: true,
          ),
        ),
      if (canOpenDetached) const PopupMenuDivider(),
      if (showPinArchive && !viewingArchived && !isArchived)
        PopupMenuItem<String>(
          value: 'pin',
          child: ListTile(
            leading: Icon(isPinned ? Icons.push_pin_outlined : Icons.push_pin),
            title: Text(isPinned ? 'Unpin chat' : 'Pin chat'),
            contentPadding: EdgeInsets.zero,
            dense: true,
          ),
        ),
      if (showPinArchive)
        PopupMenuItem<String>(
          value: 'archive',
          child: ListTile(
            leading: const Icon(Icons.archive_outlined),
            title: Text(
              viewingArchived || isArchived ? 'Unarchive chat' : 'Archive chat',
            ),
            contentPadding: EdgeInsets.zero,
            dense: true,
          ),
        ),
    ],
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
