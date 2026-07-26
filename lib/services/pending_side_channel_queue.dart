import 'package:flutter/foundation.dart';
import 'package:prysm/util/pending_message_db_helper.dart';

/// Outbox for side-channel (reaction / read-receipt / message-modify) pending
/// messages. The default implementation delegates to [PendingMessageDbHelper].
abstract class SideChannelOutbox {
  Future<void> insertDirect({
    required String id,
    required String senderId,
    required String receiverId,
    required String message,
    required String type,
    required int timestamp,
  });

  Future<void> insertGroup({
    required String id,
    required String senderId,
    required String receiverId,
    required String message,
    required String type,
    required int timestamp,
    required String groupId,
    required String targetMemberId,
  });

  Future<List<PendingSideChannel>> getPendingDirect({
    required String senderId,
    required Set<String> types,
    int? limit,
  });

  Future<List<PendingSideChannel>> getPendingDirectForReceiver({
    required String senderId,
    required String receiverId,
    required Set<String> types,
    int? limit,
  });

  Future<List<PendingSideChannel>> getPendingGroup({
    required String senderId,
    required Set<String> types,
    int? limit,
  });

  Future<void> remove(String id);

  Future<void> removeAll(List<String> ids);
}

/// A single pending side-channel delivery row.
@immutable
class PendingSideChannel {
  final String id;
  final String senderId;
  final String? receiverId;
  final String? targetMemberId;
  final String? groupId;
  final String message;
  final String type;
  final int timestamp;

  const PendingSideChannel({
    required this.id,
    required this.senderId,
    this.receiverId,
    this.targetMemberId,
    this.groupId,
    required this.message,
    required this.type,
    required this.timestamp,
  });

  factory PendingSideChannel.fromRow(Map<String, Object?> row) {
    return PendingSideChannel(
      id: row['id'] as String,
      senderId: row['senderId'] as String,
      receiverId: row['receiverId'] as String?,
      targetMemberId: row['targetMemberId'] as String?,
      groupId: row['groupId'] as String?,
      message: row['message'] as String,
      type: row['type'] as String,
      timestamp: row['timestamp'] as int,
    );
  }

  Map<String, dynamic> toPendingRow() {
    return {
      'id': id,
      'senderId': senderId,
      'receiverId': receiverId,
      'message': message,
      'type': type,
      'timestamp': timestamp,
      'status': 'pending',
      'groupId': groupId,
      'targetMemberId': targetMemberId,
    };
  }
}

/// Concrete outbox backed by the existing [PendingMessageDbHelper].
///
/// Tests can inject an in-memory database via
/// [PendingMessageDbHelper.setDatabaseForTest], or replace the entire outbox
/// with a fake implementation of [SideChannelOutbox].
class PendingSideChannelQueue implements SideChannelOutbox {
  const PendingSideChannelQueue();

  @override
  Future<void> insertDirect({
    required String id,
    required String senderId,
    required String receiverId,
    required String message,
    required String type,
    required int timestamp,
  }) async {
    await PendingMessageDbHelper.insertPendingMessage({
      'id': id,
      'senderId': senderId,
      'receiverId': receiverId,
      'message': message,
      'type': type,
      'timestamp': timestamp,
      'status': 'pending',
    });
  }

  @override
  Future<void> insertGroup({
    required String id,
    required String senderId,
    required String receiverId,
    required String message,
    required String type,
    required int timestamp,
    required String groupId,
    required String targetMemberId,
  }) async {
    await PendingMessageDbHelper.insertPendingMessage({
      'id': id,
      'senderId': senderId,
      'receiverId': receiverId,
      'message': message,
      'type': type,
      'timestamp': timestamp,
      'status': 'pending',
      'groupId': groupId,
      'targetMemberId': targetMemberId,
    });
  }

  @override
  Future<List<PendingSideChannel>> getPendingDirect({
    required String senderId,
    required Set<String> types,
    int? limit,
  }) async {
    final rows = await PendingMessageDbHelper.getPendingDirectMessages(
      senderId: senderId,
      limit: limit,
    );
    return rows
        .where((row) => types.contains(row['type'] as String?))
        .map(PendingSideChannel.fromRow)
        .toList();
  }

  @override
  Future<List<PendingSideChannel>> getPendingDirectForReceiver({
    required String senderId,
    required String receiverId,
    required Set<String> types,
    int? limit,
  }) async {
    final rows =
        await PendingMessageDbHelper.getPendingDirectMessagesForReceiver(
      senderId: senderId,
      receiverId: receiverId,
      limit: limit,
    );
    return rows
        .where((row) => types.contains(row['type'] as String?))
        .map(PendingSideChannel.fromRow)
        .toList();
  }

  @override
  Future<List<PendingSideChannel>> getPendingGroup({
    required String senderId,
    required Set<String> types,
    int? limit,
  }) async {
    final rows = await PendingMessageDbHelper.getPendingGroupChatMessages(
      senderId: senderId,
      limit: limit,
    );
    return rows
        .where((row) => types.contains(row['type'] as String?))
        .map(PendingSideChannel.fromRow)
        .toList();
  }

  @override
  Future<void> remove(String id) async {
    await PendingMessageDbHelper.removeMessage(id);
  }

  @override
  Future<void> removeAll(List<String> ids) async {
    await PendingMessageDbHelper.removeMessages(ids);
  }
}
