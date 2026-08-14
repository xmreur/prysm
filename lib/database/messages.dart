import 'package:flutter/foundation.dart';
import 'package:prysm/database/conversation_list_queries_dao.dart';
import 'package:prysm/database/conversation_queries_dao.dart';
import 'package:prysm/database/media_gallery_queries_dao.dart';
import 'package:prysm/database/message_crud_dao.dart';
import 'package:prysm/database/message_id_codec.dart';
import 'package:prysm/database/message_search_dao.dart';
import 'package:prysm/database/messages_database.dart';
import 'package:prysm/database/read_receipt_queries_dao.dart';
import 'package:prysm/util/message_insert_bus.dart';
import 'package:prysm/models/message_search_hit.dart';
import 'package:prysm/util/message_preview_label.dart' as preview_label;
import 'package:prysm/util/read_waterline_mark.dart';
import 'package:sqflite/sqflite.dart';
import 'dart:async';

/// Thin facade over the messages.db DAOs: preserves the original MessagesDb
/// static API for its ~30 consumers while the actual query/CRUD logic lives
/// in the DAO classes below (CRUD, conversation queries, read waterline,
/// conversation-list aggregates, media gallery).
class MessagesDb {
  static const MessageCrudDao _crudDao = MessageCrudDao();
  static const ConversationQueriesDao _conversationDao = ConversationQueriesDao();
  static const ReadReceiptQueriesDao _readReceiptDao = ReadReceiptQueriesDao();
  static final ConversationListQueriesDao _conversationListDao = ConversationListQueriesDao();
  static const MediaGalleryQueriesDao _mediaDao = MediaGalleryQueriesDao();
  static const MessageSearchDao _searchDao = MessageSearchDao();

  /// Stream that emits the normalized row whenever a message is inserted locally.
  static Stream<Map<String, dynamic>> get onMessageInserted =>
      MessageInsertBus.instance.onMessageInserted;

  static Future<Database> get database => MessagesDatabase.database;

  static Future<void> closeForWipe() => MessagesDatabase.closeForWipe();

  @visibleForTesting
  static void setDatabaseForTest(Database? db) {
    // ignore: invalid_use_of_visible_for_testing_member
    MessagesDatabase.setDatabaseForTest(db);
  }

  /// Storage primary key: group messages are scoped per group to avoid cross-group REPLACE.
  static String scopedId({required String wireId, String? groupId}) =>
      MessageIdCodec.scopedId(wireId: wireId, groupId: groupId);

  static String wireIdFromStorage(String storageId) =>
      MessageIdCodec.wireIdFromStorage(storageId);

  /// Mark a view-once message as viewed and wipe its content
  static Future<void> markViewOnceViewed(
    String messageId, {
    String? groupId,
  }) =>
      _crudDao.markViewOnceViewed(messageId, groupId: groupId);

  /// Insert or replace a locally-sent message (encrypted for self).
  static Future<void> insertMessage(
    Map<String, dynamic> message, {
    bool notifyListeners = true,
  }) =>
      _crudDao.insertMessage(
        message,
        notifyListeners: notifyListeners,
        onInserted: MessageInsertBus.instance.notify,
      );

  /// Insert an inbound delivery without clobbering our outbound encrypted-for-self copy.
  /// Returns the stored row, or null when an existing outbound copy is kept.
  static Future<Map<String, dynamic>?> insertInboundMessage(
    Map<String, dynamic> message,
    String localUserId,
  ) =>
      _crudDao.insertInboundMessage(message, localUserId);

  /// Loads the encrypted wire payload for a message (may read from disk).
  static Future<String?> getMessageWire(
    String messageId, {
    String? groupId,
  }) =>
      _crudDao.getMessageWire(messageId, groupId: groupId);

  /// Get the last message timestamp for a user
  static Future<int?> getLastMessageTimestampForUser(String userId) =>
      _conversationListDao.getLastMessageTimestampForUser(userId);

  /// Get the last message timestamps for all users in a single query
  static Future<Map<String, int>> getLastMessageTimestampsForAllUsers() =>
      _conversationListDao.getLastMessageTimestampsForAllUsers();

  /// Query messages between two users, newest first
  static Future<List<Map<String, dynamic>>> getMessagesBetween(
    String userId,
    String receiverId,
  ) =>
      _conversationDao.getMessagesBetween(userId, receiverId);

  /// Query message by wire ID (optionally scoped to a group).
  static Future<List<Map<String, dynamic>>> getMessageById(
    String messageId, {
    String? groupId,
  }) =>
      _crudDao.getMessageById(messageId, groupId: groupId);

  /// Get a batch of messages with optional pagination by timestamp
  static Future<List<Map<String, dynamic>>> getMessagesBetweenBatch(
    String userId,
    String receiverId, {
    int limit = 20,
    int? beforeTimestamp,
  }) =>
      _conversationDao.getMessagesBetweenBatch(
        userId,
        receiverId,
        limit: limit,
        beforeTimestamp: beforeTimestamp,
      );

  /// Get a batch of messages with pagination by timestamp and message ID for stable ordering
  static Future<List<Map<String, dynamic>>> getMessagesBetweenBatchWithId(
    String userId,
    String receiverId, {
    int limit = 20,
    int? beforeTimestamp,
    String? beforeId,
  }) =>
      _conversationDao.getMessagesBetweenBatchWithId(
        userId,
        receiverId,
        limit: limit,
        beforeTimestamp: beforeTimestamp,
        beforeId: beforeId,
      );

  /// Delete all messages between two users
  static Future<void> deleteMessagesBetween(
    String userId,
    String receiverId,
  ) =>
      _conversationDao.deleteMessagesBetween(userId, receiverId);

  static Future<void> softDeleteMessage(
    String wireId, {
    String? groupId,
    required int deletedAt,
  }) =>
      _crudDao.softDeleteMessage(wireId, groupId: groupId, deletedAt: deletedAt);

  static Future<void> updateMessageContent({
    required String wireId,
    String? groupId,
    required String encryptedMessage,
    required int editedAt,
  }) =>
      _crudDao.updateMessageContent(
        wireId: wireId,
        groupId: groupId,
        encryptedMessage: encryptedMessage,
        editedAt: editedAt,
      );

  /// Delete a message by it's id
  static Future<void> deleteMessageById(String id) =>
      _crudDao.deleteMessageById(id);

  static Future<void> hardDeleteMessage(
    String wireId, {
    String? groupId,
  }) =>
      _crudDao.hardDeleteMessage(wireId, groupId: groupId);

  static Future<void> setAsRead(String id, {String? groupId}) =>
      _readReceiptDao.setAsRead(id, groupId: groupId);

  /// Mark inbound direct messages as read locally. Returns waterline if any marked.
  static Future<ReadWaterlineMark?> markInboundConversationRead(
    String localUserId,
    String peerId,
  ) =>
      _readReceiptDao.markInboundConversationRead(localUserId, peerId);

  /// Mark inbound group messages as read locally. Returns waterline if any marked.
  static Future<ReadWaterlineMark?> markInboundGroupRead(
    String localUserId,
    String groupId,
  ) =>
      _readReceiptDao.markInboundGroupRead(localUserId, groupId);

  /// Outbound direct messages from [senderId] to [receiverId] up to [readUpToTimestamp].
  static Future<List<Map<String, dynamic>>> getOutboundDirectUpToTimestamp({
    required String senderId,
    required String receiverId,
    required int readUpToTimestamp,
  }) =>
      _readReceiptDao.getOutboundDirectUpToTimestamp(
        senderId: senderId,
        receiverId: receiverId,
        readUpToTimestamp: readUpToTimestamp,
      );

  /// Outbound group messages from [senderId] in [groupId] up to [readUpToTimestamp].
  static Future<List<Map<String, dynamic>>> getOutboundGroupUpToTimestamp({
    required String senderId,
    required String groupId,
    required int readUpToTimestamp,
  }) =>
      _readReceiptDao.getOutboundGroupUpToTimestamp(
        senderId: senderId,
        groupId: groupId,
        readUpToTimestamp: readUpToTimestamp,
      );

  /// Outbound direct chat rows still marked pending in the messages table.
  static Future<List<Map<String, dynamic>>> getPendingOutboundDirectMessages({
    required String senderId,
    required String receiverId,
  }) =>
      _readReceiptDao.getPendingOutboundDirectMessages(
        senderId: senderId,
        receiverId: receiverId,
      );

  static Future<void> updateMessageStatus(
    String messageId,
    String status, {
    String? groupId,
  }) =>
      _crudDao.updateMessageStatus(messageId, status, groupId: groupId);

  static Future<int?> getNextExpiresAt() => _crudDao.getNextExpiresAt();

  static Future<List<Map<String, dynamic>>> getExpiredMessages({
    required int cutoff,
    int limit = 100,
  }) =>
      _crudDao.getExpiredMessages(cutoff: cutoff, limit: limit);

  static Future<List<Map<String, dynamic>>> getPendingAuthDirectMessages() =>
      _crudDao.getPendingAuthDirectMessages();

  /// Get messages for a group, newest first (dedupe by id in caller)
  static Future<List<Map<String, dynamic>>> getMessagesForGroupBatch(
    String groupId, {
    int limit = 20,
    int? beforeTimestamp,
    String? beforeId,
    int? afterTimestamp,
  }) =>
      _conversationDao.getMessagesForGroupBatch(
        groupId,
        limit: limit,
        beforeTimestamp: beforeTimestamp,
        beforeId: beforeId,
        afterTimestamp: afterTimestamp,
      );

  static String previewLabelForType(String? type, {bool deleted = false}) =>
      preview_label.previewLabelForType(type, deleted: deleted);

  /// Latest message preview label per conversation id (peer onion or group id).
  static Future<Map<String, String>> getLastMessagePreviews(
    String localUserId,
  ) =>
      _conversationListDao.getLastMessagePreviews(localUserId);

  /// Unread inbound message counts per conversation id.
  static Future<Map<String, int>> getUnreadCounts(String localUserId) =>
      _conversationListDao.getUnreadCounts(localUserId);

  /// Last message timestamp per group (only messages after member joined).
  static Future<Map<String, int>> getLastMessageTimestampsForAllGroups(
    String localUserId,
  ) =>
      _conversationListDao.getLastMessageTimestampsForAllGroups(localUserId);

  static Future<void> deleteMessagesForGroup(String groupId) =>
      _conversationDao.deleteMessagesForGroup(groupId);

  static Future<void> deleteGroupMessagesBefore(
    String groupId,
    int beforeTimestamp,
  ) =>
      _conversationDao.deleteGroupMessagesBefore(groupId, beforeTimestamp);

  /// Media messages in a direct chat, newest first.
  static Future<List<Map<String, dynamic>>> getMediaMessagesForDirect(
    String userId,
    String peerId, {
    String? typeFilter,
    int limit = 50,
    int? beforeTimestamp,
  }) =>
      _mediaDao.getMediaMessagesForDirect(
        userId,
        peerId,
        typeFilter: typeFilter,
        limit: limit,
        beforeTimestamp: beforeTimestamp,
      );

  /// Media messages in a group chat, newest first.
  static Future<List<Map<String, dynamic>>> getMediaMessagesForGroup(
    String groupId, {
    String? typeFilter,
    int limit = 50,
    int? beforeTimestamp,
    int? afterTimestamp,
  }) =>
      _mediaDao.getMediaMessagesForGroup(
        groupId,
        typeFilter: typeFilter,
        limit: limit,
        beforeTimestamp: beforeTimestamp,
        afterTimestamp: afterTimestamp,
      );

  /// All media messages across every chat, newest first.
  static Future<List<Map<String, dynamic>>> getAllMediaMessages({
    List<String>? types,
    int limit = 50,
    int? beforeTimestamp,
    String? beforeId,
  }) =>
      _mediaDao.getAllMediaMessages(
        types: types,
        limit: limit,
        beforeTimestamp: beforeTimestamp,
        beforeId: beforeId,
      );

  /// Count of all media messages with stored content.
  static Future<int> countAllMediaMessages({List<String>? types}) =>
      _mediaDao.countAllMediaMessages(types: types);

  /// Close the db
  static Future<void> close() => MessagesDatabase.close();

  static Future<List<MessageSearchHit>> searchMessagesGlobal(
    String query, {
    int limit = 30,
  }) =>
      _searchDao.searchGlobal(query, limit: limit);

  static Future<List<MessageSearchHit>> searchMessagesInConversation(
    String conversationId,
    String query, {
    int limit = 50,
  }) =>
      _searchDao.searchInConversation(conversationId, query, limit: limit);
}
