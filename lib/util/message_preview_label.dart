import 'package:prysm/services/settings_service.dart';

/// Sidebar/reply preview label (emoji + text) for a message type. Shared by
/// MessagesDb (conversation-list previews) and SelfMessagesDb (notes-to-self
/// preview), and by reply_preview_label.dart's text fallback.
String previewLabelForType(String? type, {bool deleted = false}) {
  if (deleted) return SettingsService().localizations.deleted;
  switch (type) {
    case 'image':
    case 'group_image':
      return SettingsService().localizations.photoPreview;
    case 'file':
    case 'group_file':
      return SettingsService().localizations.filePreview;
    case 'audio':
    case 'group_audio':
      return SettingsService().localizations.voicePreview;
    case 'call':
      return SettingsService().localizations.callPreview;
    default:
      return SettingsService().localizations.messageHint;
  }
}
