class MessageSearchHit {
  const MessageSearchHit({
    required this.messageId,
    required this.conversationId,
    required this.scope,
    required this.timestamp,
    required this.body,
    this.snippet = '',
  });

  final String messageId;
  final String conversationId;
  final String scope;
  final int timestamp;
  final String body;
  final String snippet;

  MessageSearchHit copyWith({String? snippet}) => MessageSearchHit(
        messageId: messageId,
        conversationId: conversationId,
        scope: scope,
        timestamp: timestamp,
        body: body,
        snippet: snippet ?? this.snippet,
      );
}
