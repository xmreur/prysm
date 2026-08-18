import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:prysm/models/chat/prysm_message.dart';
import 'package:prysm/ui/core/prysm_icons.dart';
import 'package:prysm/ui/core/prysm_list_row.dart';
import 'package:prysm/ui/core/prysm_toast.dart';
import 'package:prysm/services/settings_service.dart';
import 'package:prysm/l10n/l10n_extensions.dart';

/// The plain text a message copies as, or '' when it carries none.
///
/// Call messages are deliberately not handled here: their label is built from
/// direction, status and duration by the only screen that renders them.
String messageCopyText(Message message) {
  if (message is TextMessage) return message.text;
  if (message is FileMessage) return message.name;
  if (message is ImageMessage) return SettingsService().localizations.image;
  return '';
}

/// The 'Copy' row of a message action sheet.
///
/// Shared because all three chat screens need the identical row and only the
/// 1:1 chat had it: long-pressing a message in a group or in the self-chat
/// offered no way to copy its text at all. `context` must be the screen's, not
/// the sheet builder's: the tap dismisses the sheet's route, so the context
/// must outlive the sheet.
PrysmListRow copyMessageTile({
  required BuildContext context,
  required String text,
}) {
  return PrysmListRow(
    leading: const Icon(PrysmIcons.copy),
    title: context.l10n.copy,
    onTap: () async {
      Navigator.pop(context);
      // Claiming success before the write lands makes the toast a lie when
      // the platform refuses the clipboard (PlatformException). Await it.
      try {
        await Clipboard.setData(ClipboardData(text: text));
      } catch (_) {
        if (context.mounted) showPrysmToast(context, context.l10n.couldNotCopy);
        return;
      }
      if (context.mounted) showPrysmToast(context, context.l10n.copiedToClipboard);
    },
  );
}
