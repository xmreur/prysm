/// A message the user chose to send at a future time.
///
/// [body] is the decrypted text; rows on disk keep it encrypted for self.
class ScheduledMessage {
  const ScheduledMessage({
    required this.id,
    required this.conversationId,
    required this.isGroup,
    required this.body,
    required this.sendAt,
    required this.createdAt,
    this.replyTo,
  });

  final String id;
  final String conversationId;
  final bool isGroup;
  final String body;
  final String? replyTo;
  final DateTime sendAt;
  final DateTime createdAt;

  bool isDueAt(DateTime now) => !sendAt.isAfter(now);
}
