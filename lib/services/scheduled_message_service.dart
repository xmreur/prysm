import 'package:prysm/database/scheduled_messages_db.dart';
import 'package:prysm/models/scheduled_message.dart';
import 'package:prysm/services/chat_service.dart';
import 'package:prysm/services/group_chat_service.dart';
import 'package:prysm/services/group_service.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/logging.dart';
import 'package:prysm/util/scheduled_activity_notifier.dart';
import 'package:uuid/uuid.dart';

/// Sends one scheduled message. Returns false to keep the row queued for a
/// later attempt.
typedef ScheduledSender = Future<bool> Function(ScheduledMessage message);

/// Stores messages the user chose to send later, and delivers them once their
/// time has come.
///
/// Bodies are encrypted for self at rest, so a queued message is never
/// plaintext on disk. A message whose time passed while the app was closed is
/// sent on the next flush rather than dropped.
class ScheduledMessageService {
  ScheduledMessageService({
    required this.userId,
    required this.keyManager,
    ScheduledSender? directSender,
    ScheduledSender? groupSender,
  })  : _directSender = directSender,
        _groupSender = groupSender;

  final String userId;
  final KeyManager keyManager;
  final ScheduledSender? _directSender;
  final ScheduledSender? _groupSender;

  bool _flushing = false;

  Future<ScheduledMessage> schedule({
    required String conversationId,
    required bool isGroup,
    required String text,
    required DateTime sendAt,
    String? replyToId,
  }) async {
    final id = const Uuid().v4();
    final createdAt = DateTime.now();
    await ScheduledMessagesDb.insert({
      'id': id,
      'conversationId': conversationId,
      'isGroup': isGroup ? 1 : 0,
      'body': await keyManager.encryptForSelf(text),
      'replyTo': replyToId,
      'sendAt': sendAt.millisecondsSinceEpoch,
      'createdAt': createdAt.millisecondsSinceEpoch,
    });
    ScheduledActivityNotifier.instance.notify();
    return ScheduledMessage(
      id: id,
      conversationId: conversationId,
      isGroup: isGroup,
      body: text,
      replyTo: replyToId,
      sendAt: sendAt,
      createdAt: createdAt,
    );
  }

  Future<List<ScheduledMessage>> pendingFor(String conversationId) async {
    final rows = await ScheduledMessagesDb.getForConversation(conversationId);
    return _decodeRows(rows);
  }

  Future<int> pendingCountFor(String conversationId) =>
      ScheduledMessagesDb.countForConversation(conversationId);

  /// When the earliest queued message comes due, or null when nothing is
  /// queued. Lets callers wake up at that exact moment instead of polling.
  Future<DateTime?> nextDueAt() async {
    final at = await ScheduledMessagesDb.getNextSendAt();
    return at == null ? null : DateTime.fromMillisecondsSinceEpoch(at);
  }

  Future<void> cancel(String id) async {
    await ScheduledMessagesDb.delete(id);
    ScheduledActivityNotifier.instance.notify();
  }

  Future<void> cancelForConversation(String conversationId) async {
    await ScheduledMessagesDb.deleteForConversation(conversationId);
    ScheduledActivityNotifier.instance.notify();
  }

  /// Sends every message whose time has arrived. Returns true when at least one
  /// was delivered, so callers can report progress like the other flushers.
  Future<bool> flushDue({DateTime? now}) async {
    if (_flushing) return false;
    _flushing = true;
    try {
      final at = now ?? DateTime.now();
      final due = await _decodeRows(
        await ScheduledMessagesDb.getDue(at.millisecondsSinceEpoch),
      );
      if (due.isEmpty) return false;

      var sent = 0;
      for (final message in due) {
        if (await _send(message)) {
          await ScheduledMessagesDb.delete(message.id);
          sent++;
        }
      }
      Logging.info(
        'Flushed scheduled messages: $sent/${due.length} sent',
        'ScheduledMessageService',
      );
      return sent > 0;
    } finally {
      _flushing = false;
    }
  }

  Future<bool> _send(ScheduledMessage message) async {
    try {
      final sender = message.isGroup
          ? (_groupSender ?? _sendToGroup)
          : (_directSender ?? _sendToPeer);
      return await sender(message);
    } catch (e) {
      Logging.error(
        'Scheduled send failed (${message.id}): $e',
        'ScheduledMessageService',
      );
      return false;
    }
  }

  Future<bool> _sendToPeer(ScheduledMessage message) async {
    final service = ChatService(
      userId: userId,
      peerId: message.conversationId,
      keyManager: keyManager,
    );
    try {
      if (!await service.initialize(null)) return false;
      final sentId = await service.sendTextMessage(
        message.body,
        replyToId: message.replyTo,
      );
      return sentId != null;
    } finally {
      service.dispose();
    }
  }

  Future<bool> _sendToGroup(ScheduledMessage message) async {
    final service = GroupChatService(
      userId: userId,
      groupId: message.conversationId,
      keyManager: keyManager,
      groupService: GroupService(userId: userId, keyManager: keyManager),
    );
    try {
      if (!await service.initialize()) return false;
      final sentId = await service.sendTextMessage(
        message.body,
        replyToId: message.replyTo,
      );
      return sentId != null;
    } finally {
      service.dispose();
    }
  }

  Future<List<ScheduledMessage>> _decodeRows(
    List<Map<String, dynamic>> rows,
  ) async {
    final result = <ScheduledMessage>[];
    for (final row in rows) {
      final id = row['id'] as String;
      try {
        result.add(
          ScheduledMessage(
            id: id,
            conversationId: row['conversationId'] as String,
            isGroup: (row['isGroup'] as int? ?? 0) == 1,
            body: await keyManager.decryptMessage(row['body'] as String),
            replyTo: row['replyTo'] as String?,
            sendAt: DateTime.fromMillisecondsSinceEpoch(row['sendAt'] as int),
            createdAt:
                DateTime.fromMillisecondsSinceEpoch(row['createdAt'] as int),
          ),
        );
      } catch (e) {
        Logging.error(
          'Scheduled message decrypt failed ($id): $e',
          'ScheduledMessageService',
        );
      }
    }
    return result;
  }
}
