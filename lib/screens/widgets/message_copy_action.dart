import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:prysm/models/chat/prysm_message.dart';
import 'package:prysm/ui/core/prysm_icons.dart';
import 'package:prysm/ui/core/prysm_list_row.dart';
import 'package:prysm/ui/core/prysm_toast.dart';

/// The plain text a message copies as, or '' when it carries none.
///
/// Call messages are deliberately not handled here: their label is built from
/// direction, status and duration by the only screen that renders them.
String messageCopyText(Message message) {
  if (message is TextMessage) return message.text;
  if (message is FileMessage) return message.name;
  if (message is ImageMessage) return '📷 Image';
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
    title: 'Copy',
    onTap: () {
      Navigator.pop(context);
      Clipboard.setData(ClipboardData(text: text));
      showPrysmToast(context, 'Copied to clipboard');
    },
  );
}
