/// Sidebar/reply preview label (emoji + text) for a message type. Shared by
/// MessagesDb (conversation-list previews) and SelfMessagesDb (notes-to-self
/// preview), and by reply_preview_label.dart's text fallback.
String previewLabelForType(String? type, {bool deleted = false}) {
  if (deleted) return 'Deleted';
  switch (type) {
    case 'image':
    case 'group_image':
      return '📷 Photo';
    case 'file':
    case 'group_file':
      return '📎 File';
    case 'audio':
    case 'group_audio':
      return '🎤 Voice';
    case 'call':
      return '📞 Call';
    default:
      return 'Message';
  }
}
