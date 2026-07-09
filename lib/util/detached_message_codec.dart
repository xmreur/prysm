import 'package:prysm/models/chat/prysm_message.dart';

/// JSON transport for chat messages across detached window IPC.
class DetachedMessageCodec {
  DetachedMessageCodec._();

  static Map<String, dynamic> encode(Message message) {
    if (message is TextMessage) {
      return {
        'type': 'text',
        'id': message.id,
        'authorId': message.authorId,
        'createdAt': message.createdAt?.millisecondsSinceEpoch,
        'replyToMessageId': message.replyToMessageId,
        'text': message.text,
        'metadata': message.metadata,
      };
    }
    if (message is FileMessage) {
      return {
        'type': 'file',
        'id': message.id,
        'authorId': message.authorId,
        'createdAt': message.createdAt?.millisecondsSinceEpoch,
        'replyToMessageId': message.replyToMessageId,
        'name': message.name,
        'size': message.size,
        'source': message.source,
        'metadata': message.metadata,
      };
    }
    if (message is ImageMessage) {
      return {
        'type': 'image',
        'id': message.id,
        'authorId': message.authorId,
        'createdAt': message.createdAt?.millisecondsSinceEpoch,
        'replyToMessageId': message.replyToMessageId,
        'size': message.size,
        'source': message.source,
        'metadata': message.metadata,
      };
    }
    throw UnsupportedError('Unsupported message type: ${message.runtimeType}');
  }

  static List<Map<String, dynamic>> encodeAll(Iterable<Message> messages) {
    return messages.map(encode).toList(growable: false);
  }

  static Message decode(Map<String, dynamic> map) {
    final type = map['type'] as String? ?? 'text';
    final createdAt = map['createdAt'] as int?;

    switch (type) {
      case 'text':
        return TextMessage(
          id: map['id'] as String,
          authorId: map['authorId'] as String,
          createdAt:
              createdAt != null ? DateTime.fromMillisecondsSinceEpoch(createdAt) : null,
          replyToMessageId: map['replyToMessageId'] as String?,
          text: map['text'] as String? ?? '',
          metadata: (map['metadata'] as Map?)?.cast<String, dynamic>(),
        );
      case 'file':
        return FileMessage(
          id: map['id'] as String,
          authorId: map['authorId'] as String,
          createdAt:
              createdAt != null ? DateTime.fromMillisecondsSinceEpoch(createdAt) : null,
          replyToMessageId: map['replyToMessageId'] as String?,
          name: map['name'] as String? ?? 'file',
          size: (map['size'] as num?)?.toInt() ?? 0,
          source: map['source'] as String? ?? '',
          metadata: (map['metadata'] as Map?)?.cast<String, dynamic>(),
        );
      case 'image':
        return ImageMessage(
          id: map['id'] as String,
          authorId: map['authorId'] as String,
          createdAt:
              createdAt != null ? DateTime.fromMillisecondsSinceEpoch(createdAt) : null,
          replyToMessageId: map['replyToMessageId'] as String?,
          size: (map['size'] as num?)?.toInt() ?? 0,
          source: map['source'] as String? ?? '',
          metadata: (map['metadata'] as Map?)?.cast<String, dynamic>(),
        );
      default:
        return TextMessage(
          id: map['id'] as String? ?? '',
          authorId: map['authorId'] as String? ?? '',
          createdAt:
              createdAt != null ? DateTime.fromMillisecondsSinceEpoch(createdAt) : null,
          text: 'Unsupported message type',
        );
    }
  }

  static List<Message> decodeAll(List<dynamic> raw) {
    final result = <Message>[];
    for (final item in raw) {
      try {
        if (item is! Map) continue;
        result.add(decode(item.cast<String, dynamic>()));
      } catch (_) {}
    }
    return result;
  }
}
