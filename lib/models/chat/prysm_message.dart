/// Prysm-native chat message types (replaces flutter_chat_core).
sealed class PrysmMessage {
  const PrysmMessage({
    required this.id,
    required this.authorId,
    this.replyToMessageId,
    this.createdAt,
    this.sentAt,
    this.seenAt,
    this.metadata,
    this.reactions,
  });

  final String id;
  final String authorId;
  final String? replyToMessageId;
  final DateTime? createdAt;
  final DateTime? sentAt;
  final DateTime? seenAt;
  final Map<String, dynamic>? metadata;
  final Map<String, List<String>>? reactions;
}

final class PrysmTextMessage extends PrysmMessage {
  const PrysmTextMessage({
    required super.id,
    required super.authorId,
    required this.text,
    super.replyToMessageId,
    super.createdAt,
    super.sentAt,
    super.seenAt,
    super.metadata,
    super.reactions,
  });

  final String text;

  PrysmTextMessage copyWith({
    String? id,
    String? authorId,
    String? text,
    String? replyToMessageId,
    DateTime? createdAt,
    DateTime? sentAt,
    DateTime? seenAt,
    Map<String, dynamic>? metadata,
    Map<String, List<String>>? reactions,
  }) {
    return PrysmTextMessage(
      id: id ?? this.id,
      authorId: authorId ?? this.authorId,
      text: text ?? this.text,
      replyToMessageId: replyToMessageId ?? this.replyToMessageId,
      createdAt: createdAt ?? this.createdAt,
      sentAt: sentAt ?? this.sentAt,
      seenAt: seenAt ?? this.seenAt,
      metadata: metadata ?? this.metadata,
      reactions: reactions ?? this.reactions,
    );
  }
}

final class PrysmImageMessage extends PrysmMessage {
  const PrysmImageMessage({
    required super.id,
    required super.authorId,
    required this.source,
    required this.size,
    super.replyToMessageId,
    super.createdAt,
    super.sentAt,
    super.seenAt,
    super.metadata,
    super.reactions,
  });

  final String source;
  final int size;

  PrysmImageMessage copyWith({
    String? id,
    String? authorId,
    String? source,
    int? size,
    String? replyToMessageId,
    DateTime? createdAt,
    DateTime? sentAt,
    DateTime? seenAt,
    Map<String, dynamic>? metadata,
    Map<String, List<String>>? reactions,
  }) {
    return PrysmImageMessage(
      id: id ?? this.id,
      authorId: authorId ?? this.authorId,
      source: source ?? this.source,
      size: size ?? this.size,
      replyToMessageId: replyToMessageId ?? this.replyToMessageId,
      createdAt: createdAt ?? this.createdAt,
      sentAt: sentAt ?? this.sentAt,
      seenAt: seenAt ?? this.seenAt,
      metadata: metadata ?? this.metadata,
      reactions: reactions ?? this.reactions,
    );
  }
}

final class PrysmFileMessage extends PrysmMessage {
  const PrysmFileMessage({
    required super.id,
    required super.authorId,
    required this.name,
    required this.source,
    required this.size,
    super.replyToMessageId,
    super.createdAt,
    super.sentAt,
    super.seenAt,
    super.metadata,
    super.reactions,
  });

  final String name;
  final String source;
  final int size;

  PrysmFileMessage copyWith({
    String? id,
    String? authorId,
    String? name,
    String? source,
    int? size,
    String? replyToMessageId,
    DateTime? createdAt,
    DateTime? sentAt,
    DateTime? seenAt,
    Map<String, dynamic>? metadata,
    Map<String, List<String>>? reactions,
  }) {
    return PrysmFileMessage(
      id: id ?? this.id,
      authorId: authorId ?? this.authorId,
      name: name ?? this.name,
      source: source ?? this.source,
      size: size ?? this.size,
      replyToMessageId: replyToMessageId ?? this.replyToMessageId,
      createdAt: createdAt ?? this.createdAt,
      sentAt: sentAt ?? this.sentAt,
      seenAt: seenAt ?? this.seenAt,
      metadata: metadata ?? this.metadata,
      reactions: reactions ?? this.reactions,
    );
  }
}

/// System-style call event shown inside a chat thread.
final class PrysmCallMessage extends PrysmMessage {
  const PrysmCallMessage({
    required super.id,
    required super.authorId,
    required this.durationMs,
    required this.callStatus,
    required this.direction,
    super.createdAt,
  });

  final int durationMs;
  final String callStatus;
  final String direction;

  PrysmCallMessage copyWith({
    String? id,
    String? authorId,
    int? durationMs,
    String? callStatus,
    String? direction,
    DateTime? createdAt,
  }) {
    return PrysmCallMessage(
      id: id ?? this.id,
      authorId: authorId ?? this.authorId,
      durationMs: durationMs ?? this.durationMs,
      callStatus: callStatus ?? this.callStatus,
      direction: direction ?? this.direction,
      createdAt: createdAt ?? this.createdAt,
    );
  }
}

/// Type aliases for gradual migration from flutter_chat_core names.
typedef Message = PrysmMessage;
typedef TextMessage = PrysmTextMessage;
typedef ImageMessage = PrysmImageMessage;
typedef FileMessage = PrysmFileMessage;

extension PrysmMessageCopyWith on PrysmMessage {
  PrysmMessage copyWith({
    String? id,
    String? authorId,
    String? replyToMessageId,
    DateTime? createdAt,
    DateTime? sentAt,
    DateTime? seenAt,
    Map<String, dynamic>? metadata,
    Map<String, List<String>>? reactions,
  }) {
    return switch (this) {
      PrysmTextMessage m => m.copyWith(
          id: id,
          authorId: authorId,
          replyToMessageId: replyToMessageId,
          createdAt: createdAt,
          sentAt: sentAt,
          seenAt: seenAt,
          metadata: metadata,
          reactions: reactions,
        ),
      PrysmImageMessage m => m.copyWith(
          id: id,
          authorId: authorId,
          replyToMessageId: replyToMessageId,
          createdAt: createdAt,
          sentAt: sentAt,
          seenAt: seenAt,
          metadata: metadata,
          reactions: reactions,
        ),
      PrysmFileMessage m => m.copyWith(
          id: id,
          authorId: authorId,
          replyToMessageId: replyToMessageId,
          createdAt: createdAt,
          sentAt: sentAt,
          seenAt: seenAt,
          metadata: metadata,
          reactions: reactions,
        ),
      PrysmCallMessage m => m.copyWith(
          id: id,
          authorId: authorId,
          createdAt: createdAt,
        ),
    };
  }
}
