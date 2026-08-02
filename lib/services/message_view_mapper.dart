import 'dart:convert';
import 'dart:typed_data';

import 'package:prysm/constants/group_constants.dart';
import 'package:prysm/constants/media_constants.dart';
import 'package:prysm/crypto/constants.dart';
import 'package:prysm/crypto/group_crypto.dart';
import 'package:prysm/database/message_read_receipts.dart';
import 'package:prysm/database/messages.dart';
import 'package:prysm/models/chat/prysm_message.dart';
import 'package:prysm/screens/widgets/message_reaction_bar.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/logging.dart';
import 'package:prysm/util/message_modify_policy.dart';
import 'package:prysm/util/message_status_mapper.dart';

/// Row→[Message] decrypt/mapping pipeline (Fase 6A extraction of the
/// data-layer code that used to live inline in `_ChatScreenState` and
/// `_GroupChatScreenState`).
///
/// Direct-chat rows get the full pipeline: decrypt, attach reactions,
/// attach outbound delivery/read status. Group text messages keep their
/// row→Message pipeline in `group_chat.dart` for now — it is entangled with
/// group-removal side effects (`abandonGroupAfterRemoval`) that are out of
/// scope for this phase. Only the small, side-effect-free group file/image
/// byte decrypt helper moves here.
class MessageViewMapper {
  MessageViewMapper({required this.keyManager});

  final KeyManager keyManager;

  /// Decrypts a single direct-chat text message row.
  Future<String> decryptDirectTextMessage(
    Map<String, dynamic> msg, {
    required String localUserId,
  }) async {
    final senderId = msg['senderId'] as String;
    final wire = msg['message'] as String?;
    if (wire == null || wire.isEmpty) {
      throw const FormatException('Empty message payload');
    }

    final trimmed = wire.trimLeft();
    if (trimmed.startsWith('{')) {
      final parsed = jsonDecode(wire);
      if (parsed is Map<String, dynamic>) {
        if (parsed['envelope'] == CryptoConstants.cryptoVersion) {
          throw const FormatException('Misrouted group control payload');
        }
        if (parsed.containsKey('iv') && parsed.containsKey('ct')) {
          throw const FormatException('Group-encoded payload in direct chat');
        }
      }
    }

    if (senderId == localUserId) {
      return keyManager.decryptMessage(wire);
    }

    final user = await DBHelper.getUserById(senderId);
    final identityJson = (user?['identityJson'] as String?) ??
        (user?['publicKeyPem'] as String?);
    if (identityJson == null || identityJson.isEmpty) {
      throw const FormatException('Missing peer identity');
    }
    final peerKey = keyManager.importPeerIdentity(identityJson);
    return keyManager.decryptPeerMessage(
      peerId: senderId,
      wire: wire,
      peer: peerKey,
    );
  }

  /// Maps a batch of direct-chat DB rows to [Message]s: decrypt, attach
  /// reactions, and attach outbound delivery/read status. Rows already
  /// present in [cache] are reused as-is (mirrors the widget's message
  /// cache semantics).
  Future<List<Message>> mapDirectRows(
    List<Map<String, dynamic>> rawMessages, {
    required String localUserId,
    required Map<String, Message> cache,
    required Future<Map<String, Map<String, List<String>>>> Function(
      List<String> wireIds,
    )
        loadReactionsForMessages,
    required bool readReceiptsEnabled,
  }) async {
    final messages = <Message>[];

    for (final msg in rawMessages) {
      final cached = cache[msg['id']];
      if (cached != null) {
        messages.add(cached);
        continue;
      }
      final meta = metadataFromDbRow(msg);
      if (rowShowsAsDeleted(msg, meta)) {
        messages.add(_deletedMessageFromRow(msg, {
          ...meta,
          'deleted': true,
        }));
        continue;
      }
      try {
        if (msg['type'] == 'text') {
          messages.add(
            TextMessage(
              authorId: msg['senderId'] as String,
              createdAt: DateTime.fromMillisecondsSinceEpoch(msg['timestamp']),
              id: msg['id'],
              replyToMessageId: msg['replyTo'],
              text: await decryptDirectTextMessage(
                msg,
                localUserId: localUserId,
              ),
              metadata: meta.isEmpty ? null : meta,
            ),
          );
        } else if (msg['type'] == 'file') {
          final fileName = msg['fileName'] ?? 'Unknown';
          final msgId = msg['id'] as String;
          var fileMsg = FileMessage(
            id: msgId,
            authorId: msg['senderId'] as String,
            createdAt: DateTime.fromMillisecondsSinceEpoch(msg['timestamp']),
            replyToMessageId: msg['replyTo'],
            name: fileName,
            size: msg['fileSize'] ?? 0,
            source: (msg['message'] as String?) ?? '',
            metadata: meta.isEmpty ? null : meta,
          );
          if (msg['senderId'] == localUserId) {
            fileMsg = applyOutboundStatus(
              fileMsg,
              status: outboundStatusFromDbRow(
                row: msg,
                localUserId: localUserId,
                readReceiptsEnabled: readReceiptsEnabled,
              ),
            ) as FileMessage;
          }
          messages.add(fileMsg);
        } else if (msg['type'] == 'audio') {
          messages.add(
            FileMessage(
              id: msg['id'],
              authorId: msg['senderId'] as String,
              createdAt: DateTime.fromMillisecondsSinceEpoch(msg['timestamp']),
              replyToMessageId: msg['replyTo'],
              name: msg['fileName'] ?? 'voice_message.wav',
              size: msg['fileSize'] ?? 0,
              source: msg['message'],
            ),
          );
        } else if (msg['type'] == disappearingTimerNoticeType) {
          final payload = jsonDecode((msg['message'] as String?) ?? '{}')
              as Map<String, dynamic>;
          messages.add(
            TextMessage(
              id: msg['id'],
              authorId: msg['senderId'] as String,
              createdAt: DateTime.fromMillisecondsSinceEpoch(msg['timestamp']),
              text: '',
              metadata: {
                'systemNotice': 'disappearing_timer',
                'timerSeconds': payload['timerSeconds'],
                'actorId': payload['actorId'],
              },
            ),
          );
        } else if (msg['type'] == 'call') {
          final payload = jsonDecode((msg['message'] as String?) ?? '{}')
              as Map<String, dynamic>;
          messages.add(
            PrysmCallMessage(
              id: msg['id'],
              authorId: msg['senderId'] as String,
              createdAt: DateTime.fromMillisecondsSinceEpoch(msg['timestamp']),
              durationMs: (payload['durationMs'] as num?)?.toInt() ?? 0,
              callStatus: payload['status'] as String? ?? 'completed',
              direction: payload['direction'] as String? ?? 'outbound',
            ),
          );
        } else if (msg['type'] == "image") {
          final isViewOnce = (msg['viewOnce'] ?? 0) == 1;
          final isViewed = (msg['viewed'] ?? 0) == 1;

          if (isViewOnce && isViewed) {
            // View-once already opened — show placeholder
            messages.add(
              ImageMessage(
                id: msg['id'],
                authorId: msg['senderId'] as String,
                createdAt: DateTime.fromMillisecondsSinceEpoch(msg['timestamp']),
                replyToMessageId: msg['replyTo'],
                size: 0,
                source: "",
                metadata: {'viewOnce': true, 'viewed': true},
              ),
            );
          } else {
            final msgId = msg['id'] as String;
            messages.add(
              ImageMessage(
                id: msgId,
                authorId: msg['senderId'] as String,
                createdAt: DateTime.fromMillisecondsSinceEpoch(msg['timestamp']),
                replyToMessageId: msg['replyTo'],
                size: msg['fileSize'] ?? 0,
                source: isViewOnce ? '' : deferredImageSourceFor(msgId),
                metadata: isViewOnce
                    ? {'viewOnce': true, 'viewed': false}
                    : (meta.isEmpty ? null : meta),
              ),
            );
          }
        }
      } catch (e) {
        Logging.error(
          'Direct message decrypt failed (${msg['id']}): $e',
          'MessageViewMapper',
        );
        messages.add(
          TextMessage(
            authorId: msg['senderId'] as String,
            createdAt: DateTime.fromMillisecondsSinceEpoch(msg['timestamp']),
            id: msg['id'],
            replyToMessageId: msg['replyTo'],
            text: '🔒 Unable to decrypt message',
          ),
        );
      }
    }
    final withReactions = await _attachReactions(
      messages,
      loadReactionsForMessages,
    );
    return _attachOutboundStatus(
      withReactions,
      rawMessages,
      localUserId: localUserId,
      readReceiptsEnabled: readReceiptsEnabled,
    );
  }

  Future<List<Message>> _attachReactions(
    List<Message> messages,
    Future<Map<String, Map<String, List<String>>>> Function(List<String>)
        loadReactionsForMessages,
  ) async {
    if (messages.isEmpty) return messages;
    final ids = messages.map((m) => m.id).toList();
    final reactions = await loadReactionsForMessages(ids);
    return messages
        .map((m) => applyReactionsToMessage(m, reactions[m.id]))
        .toList();
  }

  Future<List<Message>> _attachOutboundStatus(
    List<Message> messages,
    List<Map<String, dynamic>> rawRows, {
    required String localUserId,
    required bool readReceiptsEnabled,
  }) async {
    final outboundWireIds = <String>[];
    final rowByWireId = <String, Map<String, dynamic>>{};

    for (final row in rawRows) {
      final wireId = MessagesDb.wireIdFromStorage(row['id'] as String);
      if (row['senderId'] == localUserId) {
        outboundWireIds.add(wireId);
        rowByWireId[wireId] = row;
      }
    }

    if (outboundWireIds.isEmpty) return messages;

    final receipts =
        await MessageReadReceiptsDb.getReceiptsForMessages(outboundWireIds);

    return messages.map((m) {
      final row = rowByWireId[m.id];
      if (row == null) return m;
      final status = outboundStatusFromDbRow(
        row: row,
        localUserId: localUserId,
        readReceiptsEnabled: readReceiptsEnabled,
        receipts: receipts[m.id] ?? const [],
        requiredReadCount: 1,
      );
      return applyOutboundStatus(m, status: status);
    }).toList();
  }

  Message _deletedMessageFromRow(
    Map<String, dynamic> msg,
    Map<String, Object?> meta,
  ) {
    return TextMessage(
      authorId: msg['senderId'] as String,
      createdAt: DateTime.fromMillisecondsSinceEpoch(msg['timestamp'] as int),
      id: msg['id'] as String,
      replyToMessageId: msg['replyTo'] as String?,
      text: '',
      metadata: meta,
    );
  }

  /// Decrypts the raw bytes of a group file/image/voice message row.
  /// [getDecryptedGroupKey] is a tear-off of `GroupService.getDecryptedGroupKey`.
  Future<Uint8List> decryptGroupFileBytes({
    required Future<Uint8List?> Function(String groupId) getDecryptedGroupKey,
    required String groupId,
    required Map<String, dynamic> row,
  }) async {
    final groupKey = await getDecryptedGroupKey(groupId);
    if (groupKey == null) throw Exception('No group key');
    return GroupCryptoV2.decryptGroupFile(groupKey, row['message'] as String);
  }
}
