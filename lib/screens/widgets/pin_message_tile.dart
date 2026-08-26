import 'package:flutter/widgets.dart';
import 'package:prysm/l10n/l10n_extensions.dart';
import 'package:prysm/services/pinned_messages_service.dart';
import 'package:prysm/ui/core/prysm_icons.dart';
import 'package:prysm/ui/core/prysm_list_row.dart';
import 'package:prysm/ui/core/prysm_toast.dart';

PrysmListRow pinMessageTile({
  required BuildContext context,
  required bool pinned,
  required Future<void> Function() onToggle,
}) {
  return PrysmListRow(
    leading: const Icon(PrysmIcons.pushPin),
    title: pinned ? context.l10n.unpin : context.l10n.pin,
    onTap: () {
      Navigator.pop(context);
      onToggle();
    },
  );
}

Future<void> togglePinnedMessage({
  required BuildContext context,
  required String messageId,
  required String conversationId,
  required String scope,
  required Set<String> pinnedIds,
}) async {
  final pinned = pinnedIds.contains(messageId);
  if (pinned) {
    await PinnedMessagesService.unpin(
      messageId: messageId,
      conversationId: conversationId,
      scope: scope,
    );
    pinnedIds.remove(messageId);
    if (context.mounted) {
      showPrysmToast(context, context.l10n.messageUnpinned);
    }
  } else {
    await PinnedMessagesService.pin(
      messageId: messageId,
      conversationId: conversationId,
      scope: scope,
    );
    pinnedIds.add(messageId);
    if (context.mounted) {
      showPrysmToast(context, context.l10n.messagePinned);
    }
  }
}
