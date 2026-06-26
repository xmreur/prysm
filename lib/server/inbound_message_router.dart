import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:prysm/constants/group_constants.dart';
import 'package:prysm/database/messages.dart';
import 'package:prysm/services/group_service.dart';
import 'package:prysm/services/message_modify_service.dart';
import 'package:prysm/services/notification_mute_service.dart';
import 'package:prysm/services/reaction_service.dart';
import 'package:prysm/services/read_receipt_service.dart';
import 'package:prysm/services/settings_service.dart';
import 'package:prysm/services/wake_hint_service.dart';
import 'package:prysm/util/conversation_refresh_notifier.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/util/inbound_message_notifier.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/notification_service.dart';

class InboundHandleResult {
  final int statusCode;
  final Map<String, dynamic>? jsonBody;
  final String? plainTextBody;

  const InboundHandleResult({
    required this.statusCode,
    this.jsonBody,
    this.plainTextBody,
  });

  static InboundHandleResult ok(Map<String, dynamic> body) =>
      InboundHandleResult(statusCode: 200, jsonBody: body);

  static InboundHandleResult badRequest(String message) => InboundHandleResult(
        statusCode: 400,
        jsonBody: {'error': message},
      );

  static InboundHandleResult forbidden(String message) => InboundHandleResult(
        statusCode: 403,
        jsonBody: {'error': message},
      );

  static InboundHandleResult internalError([String message = 'Processing failed']) =>
      InboundHandleResult(
        statusCode: 500,
        jsonBody: {'error': message},
      );
}

/// Shared inbound routing for HTTP and WebSocket transports.
class InboundMessageRouter {
  InboundMessageRouter({
    required this.keyManager,
    required this.settings,
    required this.localOnionAddress,
    this.fetchSenderProfile,
  });

  final KeyManager keyManager;
  final SettingsService settings;
  final String? Function() localOnionAddress;
  final void Function(String senderId)? fetchSenderProfile;

  InboundHandleResult buildPublicKey() {
    return InboundHandleResult(
      statusCode: 200,
      plainTextBody: keyManager.publicKeyPem,
    );
  }

  InboundHandleResult buildProfile() {
    final broadcastName = settings.username;
    final username =
        (broadcastName != null &&
            broadcastName.isNotEmpty &&
            broadcastName != 'My Profile')
        ? broadcastName
        : '';
    return InboundHandleResult.ok({
      'publicKeyPem': keyManager.publicKeyPem,
      'username': username,
      'avatar': settings.avatar ?? '',
    });
  }

  Future<InboundHandleResult> handleSyncHint(Map<String, dynamic> data) async {
    final validationError = WakeHintService.validateSyncHintPayload(
      data,
      localOnionAddress(),
    );
    if (validationError != null) {
      return InboundHandleResult.badRequest(validationError);
    }

    final senderId = data['senderId'] as String;
    final contact = await DBHelper.getUserById(senderId);
    if (contact == null) {
      return InboundHandleResult.forbidden('Unknown sender');
    }

    unawaited(WakeHintService.instance.handleIncomingHint(senderId));
    return InboundHandleResult.ok({'status': 'ok'});
  }

  Future<InboundHandleResult> handleMessage(Map<String, dynamic> data) async {
    print('InboundMessageRouter: Received ${data['type']} from ${data['senderId']}');

    final type = data['type'] as String;

    if (!_isValidMessageData(data)) {
      return InboundHandleResult.badRequest(
        'Missing required fields: id, senderId, receiverId, message, type, timestamp',
      );
    }

    if (isGroupControlType(type)) {
      return _handleGroupControl(data, type);
    }

    if (isMessageModifyType(type)) {
      return _handleMessageModify(data, type);
    }

    if (isReadReceiptType(type)) {
      return _handleReadReceipt(data, type);
    }

    if (isReactionType(type)) {
      return _handleReaction(data, type);
    }

    if ([
          'file',
          'image',
          'audio',
          groupFileType,
          groupImageType,
          groupAudioType,
        ].contains(type) &&
        !_hasValidFileMetadata(data)) {
      return InboundHandleResult.badRequest(
        'File metadata required: fileName, fileSize',
      );
    }

    if (isGroupMessageType(type) && data['groupId'] == null) {
      return InboundHandleResult.badRequest('groupId required for group messages');
    }

    return _handleChatMessage(data, type);
  }

  Future<InboundHandleResult> _handleGroupControl(
    Map<String, dynamic> data,
    String type,
  ) async {
    final receiverId = data['receiverId'] as String;
    final local = localOnionAddress();
    if (local != null && receiverId != local) {
      return InboundHandleResult.forbidden(
        'Control message not addressed to this node',
      );
    }

    await DBHelper.ensureUserExist(data['senderId'] as String);
    fetchSenderProfile?.call(data['senderId'] as String);

    final localId = local ?? receiverId;
    final groupService = GroupService(userId: localId, keyManager: keyManager);
    try {
      await groupService.handleIncomingControlMessage(
        type,
        data['message'] as String,
      );
    } catch (e) {
      print('InboundMessageRouter: group control handling failed: $e');
      return InboundHandleResult.internalError('Group control processing failed');
    }

    return InboundHandleResult.ok({'status': 'received', 'id': data['id']});
  }

  Future<InboundHandleResult> _handleMessageModify(
    Map<String, dynamic> data,
    String type,
  ) async {
    final receiverId = data['receiverId'] as String;
    final senderId = data['senderId'] as String;
    final local = localOnionAddress();

    if (local != null) {
      if (senderId == local) {
        return InboundHandleResult.ok({'status': 'received', 'id': data['id']});
      }
      if (receiverId != local) {
        return InboundHandleResult.forbidden('Message not addressed to this node');
      }
    }

    if (type == groupMessageModifyType && data['groupId'] == null) {
      return InboundHandleResult.badRequest('groupId required for group message modifies');
    }

    await DBHelper.ensureUserExist(senderId);

    final localId = local ?? receiverId;
    final groupService = GroupService(userId: localId, keyManager: keyManager);

    try {
      await MessageModifyService.applyInbound(
        keyManager: keyManager,
        encrypted: data['message'] as String,
        senderId: senderId,
        type: type,
        groupId: data['groupId'] as String?,
        groupService: groupService,
      );
    } catch (e) {
      print('InboundMessageRouter: message modify handling failed: $e');
      return InboundHandleResult.internalError('Message modify processing failed');
    }

    return InboundHandleResult.ok({'status': 'received', 'id': data['id']});
  }

  Future<InboundHandleResult> _handleReadReceipt(
    Map<String, dynamic> data,
    String type,
  ) async {
    final receiverId = data['receiverId'] as String;
    final senderId = data['senderId'] as String;
    final local = localOnionAddress();

    if (local != null) {
      if (senderId == local) {
        return InboundHandleResult.ok({'status': 'received', 'id': data['id']});
      }
      if (receiverId != local) {
        return InboundHandleResult.forbidden('Message not addressed to this node');
      }
    }

    if ((type == groupReadReceiptType || type == groupReadWaterlineType) &&
        data['groupId'] == null) {
      return InboundHandleResult.badRequest('groupId required for group read receipts');
    }

    await DBHelper.ensureUserExist(senderId);

    final localId = local ?? receiverId;
    final groupService = GroupService(userId: localId, keyManager: keyManager);

    try {
      await ReadReceiptService.applyInbound(
        keyManager: keyManager,
        encrypted: data['message'] as String,
        senderId: senderId,
        localUserId: localId,
        type: type,
        groupId: data['groupId'] as String?,
        groupService: groupService,
      );
    } catch (e) {
      print('InboundMessageRouter: read receipt handling failed: $e');
      return InboundHandleResult.internalError('Read receipt processing failed');
    }

    return InboundHandleResult.ok({'status': 'received', 'id': data['id']});
  }

  Future<InboundHandleResult> _handleReaction(
    Map<String, dynamic> data,
    String type,
  ) async {
    final receiverId = data['receiverId'] as String;
    final senderId = data['senderId'] as String;
    final local = localOnionAddress();

    if (local != null) {
      if (senderId == local) {
        return InboundHandleResult.ok({'status': 'received', 'id': data['id']});
      }
      if (receiverId != local) {
        return InboundHandleResult.forbidden('Message not addressed to this node');
      }
    }

    if (type == groupReactionType && data['groupId'] == null) {
      return InboundHandleResult.badRequest('groupId required for group reactions');
    }

    await DBHelper.ensureUserExist(senderId);

    final localId = local ?? receiverId;
    final groupService = GroupService(userId: localId, keyManager: keyManager);

    try {
      await ReactionService.applyInbound(
        keyManager: keyManager,
        encrypted: data['message'] as String,
        senderId: senderId,
        type: type,
        groupId: data['groupId'] as String?,
        groupService: groupService,
      );
    } catch (e) {
      print('InboundMessageRouter: reaction handling failed: $e');
      return InboundHandleResult.internalError('Reaction processing failed');
    }

    return InboundHandleResult.ok({'status': 'received', 'id': data['id']});
  }

  Future<InboundHandleResult> _handleChatMessage(
    Map<String, dynamic> data,
    String type,
  ) async {
    final receiverId = data['receiverId'] as String;
    final senderId = data['senderId'] as String;
    final local = localOnionAddress();

    if (local != null) {
      if (senderId == local) {
        return InboundHandleResult.ok({'status': 'received', 'id': data['id']});
      }
      if (receiverId != local) {
        return InboundHandleResult.forbidden('Message not addressed to this node');
      }
    }

    await DBHelper.ensureUserExist(senderId);
    fetchSenderProfile?.call(senderId);

    final timeReceived = DateTime.now().millisecondsSinceEpoch;
    final incomingTimestamp = data['timestamp'];
    final messageTimestamp = incomingTimestamp is int && incomingTimestamp > 0
        ? incomingTimestamp
        : timeReceived;

    final inboundGroupId = data['groupId'] as String?;
    final localUserId = local;
    if (inboundGroupId != null && localUserId != null) {
      final joinedAt = await DBHelper.getMemberJoinedAt(
        inboundGroupId,
        localUserId,
      );
      if (joinedAt != null && messageTimestamp < joinedAt) {
        return InboundHandleResult.ok({'status': 'received', 'id': data['id']});
      }
    }

    final localId = local ?? receiverId;
    final inserted = await MessagesDb.insertInboundMessage({
      'id': data['id'] as String,
      'senderId': senderId,
      'receiverId': receiverId,
      'message': data['message'] as String,
      'type': type,
      if (data['groupId'] != null) 'groupId': data['groupId'] as String,
      if (data['fileName'] != null) 'fileName': data['fileName'] as String,
      if (data['fileSize'] != null) 'fileSize': data['fileSize'],
      'timestamp': messageTimestamp,
      'status': (data['status'] ?? 'received') as String,
      if (data['replyTo'] != null) 'replyTo': data['replyTo'],
      'viewOnce': (data['viewOnce'] == true || data['viewOnce'] == 1) ? 1 : 0,
    }, localId);

    if (inserted != null) {
      InboundMessageNotifier.instance.notify(
        InboundMessageEvent.fromRow(inserted),
      );
    }

    ConversationRefreshNotifier.instance.notifyInboundMessage();

    if (settings.enableNotifications) {
      final appState = WidgetsBinding.instance.lifecycleState;
      if (appState == AppLifecycleState.paused ||
          appState == AppLifecycleState.inactive ||
          appState == AppLifecycleState.detached) {
        final groupId = data['groupId'] as String?;
        final muteService = NotificationMuteService.instance;
        final muted = groupId != null
            ? muteService.isMuted(MuteTarget.group, groupId)
            : muteService.isMuted(MuteTarget.user, senderId);
        if (!muted) {
          final contact = await DBHelper.getUserById(senderId);
          final senderName = contact?['name'] ?? 'Unknown contact';
          final body = isGroupMessageType(type)
              ? 'New group message from $senderName'
              : 'Open to view the message';
          NotificationService().showNewMessageNotification(
            senderName: isGroupMessageType(type) ? 'Group chat' : senderName,
            message: body,
            notificationId: Random().nextInt(99999999),
            payload: jsonEncode({'senderId': senderId, 'groupId': ?groupId}),
          );
        }
      }
    }

    return InboundHandleResult.ok({
      'status': 'received',
      'id': data['id'],
      'timestamp': timeReceived,
    });
  }

  bool _isValidMessageData(dynamic data) {
    return data is Map &&
        data['id'] is String &&
        data['senderId'] is String &&
        data['receiverId'] is String &&
        data['message'] is String &&
        data['type'] is String &&
        data['timestamp'] is int;
  }

  bool _hasValidFileMetadata(dynamic data) {
    return data['fileName'] is String && data['fileSize'] is int;
  }
}
